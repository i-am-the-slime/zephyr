-- Tree shaking of type classes instance methods on CoreFn
module Language.PureScript.DCE.TypeClassInstances
  ( dceInstances ) where

import           Prelude.Compat
import           Control.Arrow ((***), (&&&), first)
import           Control.Applicative ((<|>))
import           Control.Comonad.Cofree
import           Control.Monad
import           Control.Monad.State
import           Data.Graph
import           Data.List (any, elem, filter, groupBy, sortBy)
import qualified Data.Map.Strict as M
import           Data.Maybe (Maybe(..), catMaybes, fromMaybe, mapMaybe)
import           Data.Monoid (Alt(Alt), getAlt)
import qualified Data.Set as S
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Language.PureScript as P
import           Language.PureScript.CoreFn
import           Language.PureScript.Names
import           Language.PureScript.PSString (PSString, decodeString, mkString)

import           Language.PureScript.DCE.Utils

type ModuleDict = M.Map ModuleName (ModuleT () Ann)

-- |
-- Information gethered from `CoreFn.Meta.IsTypeClassConstructor`
type TypeClassDict = M.Map (Qualified (ProperName 'ClassName)) [(PSString, Maybe (Qualified (ProperName 'ClassName)))]

data InstanceDict = InstanceDict
  { instTypeClass :: Qualified (ProperName 'ClassName)
  , instExpr :: Expr Ann
  }
type Instances = M.Map (Qualified Ident) InstanceDict 
-- ^
-- Dictionary of all instances accross all modules.
--
-- It allows to efficiently check if an identifier used in an expression is an
-- instance declaration.

isInstance :: Qualified Ident -> Instances -> Bool
isInstance (Qualified Nothing _) _ = False
isInstance ident dict = ident `M.member` dict

data TypeClassInstDepsData = TypeClassInstDepsData
  { tciClassName :: Qualified (ProperName 'ClassName)
  , tciName :: PSString
  }
type TypeClassInstDeps = Cofree Maybe TypeClassInstDepsData
-- ^
-- Tree structure that encodes information about type
-- class instance dependencies for constrained types.  Each constrain will map
-- to one `TypeClassInstanceDeps`.
--
-- `tciClassName` is the _TypeClass_ name
-- `tciName` is the field name of a member or parent type class used in
-- generated code.  This information is available in
-- `Language.PureScript.CoreFn.Meta` (see
-- [corefn-typeclasses](https://github.com/coot/purescript/blob/corefn-typeclasses/src/Language/PureScript/CoreFn/Meta.hs#L29)
-- branch of my `purescript` repo clone).

type InstanceMethodsDict = M.Map (Qualified Ident) TypeClassInstDepsData
-- ^ Dictionary of all instance method functions, e.g.
-- ```
-- Control.Applicative.apply
-- ```
-- will correspond to
-- ```
-- ```
-- ("apply", Control.Applicative.Applicative)
-- ```

-- |
-- PureScript generates thes functions that access members of type class
-- dictionaries.  This checks if an expression is such an abstraction.
isInstanceMethod :: TypeClassDict -> Expr Ann -> Maybe TypeClassInstDepsData
isInstanceMethod tyd (Abs (_, _, Just ty, _) ident (Accessor _ acc (Var _ (Qualified Nothing ident'))))
  | Just c <- mConstraint
  , ident == ident'
  -- check that the constraintClass has the given member
  , Just True <- elem (acc, Nothing) <$> (P.constraintClass c `M.lookup` tyd)
    = Just $ TypeClassInstDepsData (P.constraintClass c) acc
  where
    mConstraint :: Maybe P.Constraint
    mConstraint = getAlt $ P.everythingOnTypes (<|>) go ty
      where
      go (P.ConstrainedType c _) = Alt (Just c)
      go _ = Alt Nothing
isInstanceMethod _ _ = Nothing

dceInstances :: forall t. [ModuleT t Ann] -> [ModuleT t Ann]
dceInstances mods = undefined
  where
  instanceDict :: Instances
  instanceDict = M.fromList (instancesInModule `concatMap` mods)
    where
    instancesInModule :: ModuleT t Ann -> [(Qualified Ident, InstanceDict)]
    instancesInModule =
        concatMap instanceDicts
      . uncurry zip
      . first repeat
      . (moduleName &&& moduleDecls)

    instanceDicts :: (ModuleName, Bind Ann) -> [(Qualified Ident, InstanceDict)]
    instanceDicts (mn, NonRec _ i e)  | Just tyClsName <- isInstanceOf e = [(mkQualified i mn, InstanceDict tyClsName e)]
                                      | otherwise = []
    instanceDicts (mn, Rec bs) = mapMaybe
      (\((_, i), e) ->
        case isInstanceOf e of
          Just tyClsName  -> Just (mkQualified i mn, InstanceDict tyClsName e)
          Nothing         -> Nothing)
      bs

  typeClassDict :: TypeClassDict
  typeClassDict = execState (sequence_ [onModule m | m <- mods])  M.empty
    where
    onModule (Module _ mn _ _ _ decls) = sequence_ [ onDecl mn decl | decl <- decls ]

    onDecl :: ModuleName -> Bind Ann -> State TypeClassDict ()
    onDecl mn (NonRec _ i e) = onExpr (mkQualified (identToProper i) mn) e
    onDecl mn (Rec bs) = mapM_ (\((_, i), e) -> onExpr (mkQualified (identToProper i) mn) e) bs

    onExpr :: Qualified (ProperName 'ClassName) -> Expr Ann -> State TypeClassDict ()
    onExpr ident (Abs (_, _, _, Just (IsTypeClassConstructor mbs)) _ _)
      = modify (M.insert ident (first mkString `map` mbs))
    onExpr _ _ = return ()

  instanceMethodsDict :: InstanceMethodsDict
  instanceMethodsDict = execState (sequence_ [onModule m | m <- mods]) M.empty
    where
    onModule (Module _ mn _ _ _ decls) = sequence_ [ onDecl mn decl | decl <- decls ]

    onDecl :: ModuleName -> Bind Ann -> State InstanceMethodsDict ()
    onDecl mn (NonRec _ i e) = onExpr (mkQualified i mn) e
    onDecl mn (Rec bs) = mapM_ (\((_, i), e) -> onExpr (mkQualified i mn) e) bs

    onExpr :: Qualified Ident -> Expr Ann -> State InstanceMethodsDict ()
    onExpr i e | Just x <- isInstanceMethod typeClassDict e = modify (M.insert i x)
               | otherwise                    = pure ()
  
-- | returns type class instance of an instance declaration
isInstanceOf :: Expr Ann -> Maybe (Qualified (ProperName 'ClassName))
isInstanceOf = getAlt . go
  where
  (_, go, _, _) = everythingOnValues (<|>) (const (Alt Nothing)) isClassConstructorOf (const (Alt Nothing)) (const (Alt Nothing))

  isClassConstructorOf :: Expr Ann -> Alt Maybe (Qualified (ProperName 'ClassName))
  isClassConstructorOf (Var (_, _, _, Just (IsTypeClassConstructorApp cn)) _) = Alt (Just cn)
  isClassConstructorOf _ = Alt Nothing

-- |
-- Get all type class names for a constrained type.
typeClassNames :: P.Type -> [Qualified (ProperName 'ClassName)]
typeClassNames (P.ForAll _ ty _) = typeClassNames ty
typeClassNames (P.ConstrainedType c ty) = P.constraintClass c : typeClassNames ty
typeClassNames _ = []

-- |
-- Get all instance names used by an expression.
exprInstances :: Instances -> Expr Ann -> [Qualified Ident]
exprInstances d = go
  where
  (_, go, _, _) = everythingOnValues (++) (const []) onExpr (const []) (const [])

  onExpr :: Expr Ann -> [Qualified Ident]
  onExpr (Var _ i) | i `isInstance` d = [i]
  onExpr _ = []

-- |
-- Find all instance dependencies of an expression with a constrained type
exprInstDeps :: InstanceMethodsDict -> Expr Ann -> [TypeClassInstDeps]
exprInstDeps imd e@(Abs _ ident expr)
              | Just (P.Constraint tc args _)  <- isConstrained e = undefined
              | otherwise = []

-- |
-- For a given _constrained_ expression, we need to find out all the instances
-- that are used.  For each set of them we pair them with the corresponsing
-- `TypeClassInstDeps` and compute all memeber that are used.
compDeps :: [(InstanceDict, TypeClassInstDeps)] -> [(Qualified Ident, [Ident])]
compDeps = undefined

-- |
-- Find all instance dependencies of a class member instance.
-- The result is an instance name with the list of all members of its class
-- that are used.
-- 
-- This is much simpler that `exprInstDeps` since in member declarations,
-- instances are mentioned directly.
memberDeps :: Expr Ann -> [(Qualified Ident, [Ident])]
memberDeps = undefined

-- |
-- DCE not used instance members.
--
-- instances that are not used can be turned into plain empty objects `{}`
-- memerbs that are not used can be truend into `function() {}`
--
-- One could provide a safe option where accessing a property of dce'ed
-- indnstance raises an informative error, the same for methods,
-- ```
-- function() {throw Error('this apple felt from the tree ;)');}
-- ```
transformExpr :: [(Qualified Ident, [Ident])] -> Expr Ann -> Expr Ann
transformExpr = undefined