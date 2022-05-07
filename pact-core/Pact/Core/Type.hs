{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE PatternSynonyms #-}


module Pact.Core.Type
 ( PrimType(..)
 , Type(..)
 , RowObject
 , Row(..)
 , InterfaceType(..)
 , ModuleType(..)
 , pattern TyInt
 , pattern TyDecimal
 , pattern TyTime
 , pattern TyBool
 , pattern TyString
 , pattern TyUnit
 , tyFunToArgList
 , traverseRowTy
 , typeOfLit
 ) where

import Control.Lens
import qualified Data.Map.Strict as Map
import Pact.Types.Exp (Literal(..))
import Pact.Core.Names


data PrimType =
  PrimInt |
  PrimDecimal |
  PrimTime |
  PrimBool |
  PrimString |
  PrimUnit
  deriving (Eq,Ord,Show)

type RowObject n = Map.Map Field (Type n)

data Row n
  = RowTy (RowObject n) (Maybe n)
  | RowVar n
  | EmptyRow
  deriving (Eq, Show)

newtype InterfaceType n
  = InterfaceType n
  deriving (Eq, Show)

data ModuleType n
  = ModuleType n [n]
  deriving (Eq, Show)

-- Todo: caps are a bit strange here
-- same with defpacts. Not entirely sure how to type those yet.
-- | Our internal core type language
--   Tables, rows and and interfaces are quite similar,
--    t ::= B
--      |   v
--      |   t -> t
--      |   row
--      |   list<t>
--      |   interface name row
--
--    row  ::= {name:t, row*}
--    row* ::= name:t | ϵ
data Type n
  = TyVar n
  | TyPrim PrimType
  | TyFun (Type n) (Type n)
  | TyRow (Row n)
  -- ^ Row objects
  | TyList (Type n)
  -- ^ List aka [a]
  | TyTable (Row n)
  -- ^ Named tables.
  | TyCap
  -- ^ Capabilities
  -- Atm, until we have a proper constraint system,
  -- caps will simply be enforced @ runtime.
  -- Later on, however, it makes sense to have the set of nominally defined caps in the constraints of a function.
  | TyInterface (InterfaceType n)
   -- ^ interfaces, which are nominal
  | TyModule (ModuleType n)
  -- ^ module type being the name of the module + implemented interfaces.
  | TyForall [n] [n] (Type n)
  -- ^ Universally quantified types, which have to be part of the type
  -- constructor since system F
  -- Todo: probably want `NonEmpty a` here since TyForall [] [] t = t
  deriving (Show, Eq)

pattern TyInt :: Type n
pattern TyInt = TyPrim PrimInt

pattern TyDecimal :: Type n
pattern TyDecimal = TyPrim PrimDecimal

pattern TyTime :: Type n
pattern TyTime = TyPrim PrimTime

pattern TyBool :: Type n
pattern TyBool = TyPrim PrimBool

pattern TyString :: Type n
pattern TyString = TyPrim PrimString

pattern TyUnit :: Type n
pattern TyUnit = TyPrim PrimUnit

tyFunToArgList :: Type n -> Maybe ([Type n], Type n)
tyFunToArgList (TyFun l r) =
  unFun [l] r
  where
  unFun args (TyFun l' r') = unFun (l':args) r'
  unFun args ret = Just (reverse args, ret)
tyFunToArgList _ = Nothing

traverseRowTy :: Traversal' (Row n) (Type n)
traverseRowTy f = \case
  RowTy tys rv -> RowTy <$> traverse f tys <*> pure rv
  RowVar n -> pure (RowVar n)
  EmptyRow -> pure EmptyRow


instance Plated (Type n) where
  plate f = \case
    TyVar n -> pure (TyVar n)
    TyPrim k -> pure (TyPrim k)
    TyFun l r -> TyFun <$> f l <*> f r
    TyRow rows -> TyRow <$> traverseRowTy f rows
    TyList t -> TyList <$> f t
    TyTable r -> TyTable <$> traverseRowTy f r
    TyCap -> pure TyCap
    TyInterface n ->
      pure $ TyInterface n
    TyModule n -> pure $ TyModule n
    TyForall ns rs ty ->
      TyForall ns rs <$> f ty


typeOfLit :: Literal -> Type n
typeOfLit = TyPrim . \case
  LString{} -> PrimString
  LInteger{} -> PrimInt
  LDecimal{} -> PrimDecimal
  LBool{} -> PrimBool
  LTime{} -> PrimTime
