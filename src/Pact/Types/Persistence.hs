{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module      :  Pact.Types.Persistence
-- Copyright   :  (C) 2016 Stuart Popejoy
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>
--
-- Persistence and back-end DB types.
--
module Pact.Types.Persistence
  (
   RowKey(..),
   Domain(..),
   TxLog(..),txDomain,txKey,txValue,
   WriteType(..),
   Method,
   PactDb(..),
   TxId(..),
   PersistDirect(..),toPersistDirect,fromPersistDirect,
   ModuleData(..),mdModule,mdRefMap, mdDependencies,
   PersistModuleData,
   ExecutionMode(..),
   allModuleExports
   ) where

import Control.Applicative ((<|>))
import Control.Concurrent.MVar (MVar)
import Control.DeepSeq (NFData)
import Control.Lens (makeLenses)
import Data.Aeson hiding (Object)
import qualified Data.Aeson as A
import Data.Default
import Data.Hashable (Hashable)
import Data.Maybe(fromMaybe)
import qualified Data.HashMap.Strict as HM
import Data.String (IsString(..))
import Data.Text (Text, pack)
import Data.Typeable (Typeable)
import Data.Word (Word64)
import GHC.Generics (Generic)

import Test.QuickCheck

import Pact.Types.Continuation
import Pact.Types.Exp
import Pact.Types.PactValue
import Pact.Types.Pretty
import Pact.Types.RowData
import Pact.Types.Term
import Pact.Types.Type
import Pact.Types.Util (AsString(..), tShow, JsonProperties, enableToJSON, (.?=))
import Pact.Types.Namespace
import Pact.Utils.LegacyValue

data PersistDirect =
    PDValue PactValue
  | PDNative NativeDefName
  | PDFreeVar FullyQualifiedName
  deriving (Eq,Show,Generic)

instance NFData PersistDirect

instance ToJSON PersistDirect where
  toJSON = enableToJSON "Pact.Types.Persistence.PersistDirect" . object . \case
    (PDValue v) -> [ "pdval" .= v ]
    (PDNative n) -> [ "pdnat" .= n ]
    (PDFreeVar n) -> [ "pdfv" .= n]

  toEncoding (PDValue v) = pairs $ "pdval" .= v
  toEncoding (PDNative n) = pairs $ "pdnat" .= n
  toEncoding (PDFreeVar n) = pairs $ "pdfv" .= n

  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance FromJSON PersistDirect where
  parseJSON v =
    withObject "PDFreeVar" (\o -> PDFreeVar <$> o .: "pdfv") v <|>
    withObject "PDValue" (\o -> PDValue <$> o .: "pdval") v <|>
    withObject "PDNative" (\o -> PDNative <$> o .: "pdnat") v


instance Pretty PersistDirect where
  pretty (PDValue v) = pretty v
  pretty (PDNative n) = pretty $ "<native>" <> asString n
  pretty (PDFreeVar f) = pretty f

instance Arbitrary PersistDirect where
  arbitrary = oneof [PDValue <$> arbitrary, PDNative <$> arbitrary, PDFreeVar <$> arbitrary]

toPersistDirect :: Term Name -> Either Text PersistDirect
toPersistDirect (TNative n _ _ _ _ _ _) = pure $ PDNative n
toPersistDirect (TSchema n Nothing _ _ _) = pure $ PDNative (NativeDefName (asString n))
toPersistDirect (TConst carg Nothing _ _ _) = pure $ PDNative (NativeDefName $ _aName carg)
toPersistDirect (TVar (FQName f) _) = pure $ PDFreeVar f
toPersistDirect t = case toPactValue t of
  Right v -> pure $ PDValue v
  Left e -> Left e

fromPersistDirect :: (NativeDefName -> Maybe (Term Name)) -> PersistDirect -> Either Text (Term Name)
fromPersistDirect _ (PDValue v) = return $ fromPactValue v
fromPersistDirect _ (PDFreeVar f) = return $ TVar (FQName f) def
fromPersistDirect natLookup (PDNative nn) = case natLookup nn of
  Just t -> return t
  Nothing -> Left $ "Native lookup failed: " <> tShow nn

allModuleExports :: ModuleData Ref -> HM.HashMap FullyQualifiedName Ref
allModuleExports md = case _mdModule md of
  MDModule m ->
    let toFQ k = FullyQualifiedName k (_mName m) (_mhHash (_mHash m))
    in HM.mapKeys toFQ (_mdRefMap md) `HM.union` (_mdDependencies md)
  _ -> HM.empty

-- | Module ref store
data ModuleData r = ModuleData
  { _mdModule :: ModuleDef (Def r)
  , _mdRefMap :: HM.HashMap Text r
  , _mdDependencies :: HM.HashMap FullyQualifiedName r
  } deriving (Eq, Show, Generic, Functor, Foldable, Traversable)
makeLenses ''ModuleData

instance NFData r => NFData (ModuleData r)

instance ToJSON r => ToJSON (ModuleData r) where
  toJSON o = enableToJSON "Pact.Types.Persistence.ModuleData r" $ A.Object $ mconcat
    [ "dependencies" .?= if HM.null (_mdDependencies o)
      then Nothing
      else Just (_mdDependencies o)
    , "module" .= _mdModule o
    , "refMap" .= _mdRefMap o
    ]
  toEncoding o = pairs $ mconcat
    [ "dependencies" .?= if HM.null (_mdDependencies o)
      then Nothing
      else Just (legacyHashMap $ _mdDependencies o)
    , "module" .= _mdModule o
    , "refMap" .= legacyHashMap (_mdRefMap o)
    ]
  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance (ToJSON r, FromJSON r) => FromJSON (ModuleData r) where
  parseJSON =
    withObject "ModuleData" $ \o ->
      ModuleData
      <$> o .: "module"
      <*> o .: "refMap"
      <*> (fromMaybe HM.empty <$> o .:? "dependencies")

instance Arbitrary r => Arbitrary (ModuleData r) where
  arbitrary = ModuleData
    <$> arbitrary
    <*> scale (min 10) arbitrary
    <*> scale (min 10) arbitrary

type PersistModuleData = ModuleData (Ref' PersistDirect)

instance ToJSON (Ref' PersistDirect) where
  toJSON = enableToJSON "Pact.Types.Persistence.ModuleData r" . object . \case
    (Ref t) -> [ "ref" .= t ]
    (Direct pd) -> [ "direct" .= pd ]

  toEncoding (Ref t) = pairs ("ref" .= t)
  toEncoding (Direct pd) = pairs ("direct" .= pd)

  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance FromJSON (Ref' PersistDirect) where
  parseJSON v =
    withObject "Ref" (\o -> Ref <$> o .: "ref") v <|>
    withObject "Direct" (\o -> Direct <$> o .: "direct") v
  {-# INLINE parseJSON #-}

-- | Row key type for user tables.
newtype RowKey = RowKey Text
    deriving (Eq,Ord,Generic)
    deriving newtype (IsString,ToTerm,AsString,Show,Pretty,NFData)

instance Arbitrary RowKey where
  arbitrary = RowKey <$> arbitrary

-- | Specify key and value types for database domains.
data Domain k v where
  -- | User tables accept a TableName and map to an 'ObjectMap PactValue'
  UserTables :: !TableName -> Domain RowKey RowData
  -- | Keysets
  KeySets :: Domain KeySetName KeySet
  -- | Modules
  Modules :: Domain ModuleName PersistModuleData
  -- | Namespaces
  Namespaces :: Domain NamespaceName (Namespace PactValue)
  -- | Pacts map to 'Maybe PactExec' where Nothing indicates
  -- a terminated pact.
  Pacts :: Domain PactId (Maybe PactExec)

deriving instance Eq (Domain k v)
deriving instance Show (Domain k v)
instance AsString (Domain k v) where
    asString (UserTables t) = asString t
    asString KeySets = "SYS:KeySets"
    asString Modules = "SYS:Modules"
    asString Namespaces = "SYS:Namespaces"
    asString Pacts = "SYS:Pacts"

-- | Transaction record.
data TxLog v =
    TxLog {
      _txDomain :: !Text
    , _txKey :: !Text
    , _txValue :: !v
    }
    deriving (Eq,Show,Typeable,Generic,Foldable,Functor,Traversable)
    deriving anyclass (Hashable, NFData)
makeLenses ''TxLog

txLogProperties :: (ToJSON v) => JsonProperties (TxLog v)
txLogProperties o =
  [ "value" .= _txValue o
  , "key" .= _txKey o
  , "table" .= _txDomain o
  ]
{-# INLINE txLogProperties #-}

instance ToJSON v => ToJSON (TxLog v) where
  toJSON = enableToJSON "Pact.Types.Persistence.TxLog" . object . txLogProperties
  toEncoding = pairs . mconcat . txLogProperties
  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance FromJSON v => FromJSON (TxLog v) where
    parseJSON = withObject "TxLog" $ \o ->
                TxLog <$> o .: "table" <*> o .: "key" <*> o .: "value"

instance Pretty v => Pretty (TxLog v) where
  pretty (TxLog domain key value) = commaBrackets
    [ "table: " <> pretty domain
    , "key: "   <> pretty key
    , "value: " <> pretty value
    ]

instance Arbitrary v => Arbitrary (TxLog v) where
  arbitrary = TxLog <$> arbitrary <*> arbitrary <*> arbitrary

-- | Instruction for '_writeRow'.
data WriteType =
  -- | Insert a new row, fail if key already found.
  --   Requires complete row value, enforced by pact runtime.
  Insert |
  -- | Update an existing row, fail if key not found.
  --   Allows incomplete row values.
  Update |
  -- | Update an existing row, or insert a new row if not found.
  --   Requires complete row value, enforced by pact runtime.
  Write
  deriving (Eq,Ord,Show,Enum,Bounded)

instance Pretty WriteType where
  pretty g = case g of
    Insert -> "Insert"
    Update -> "Update"
    Write -> "Write"


-- | Transaction ids are non-negative 64-bit integers and
--   are expected to be monotonically increasing.
newtype TxId = TxId Word64
    deriving (Eq,Ord,Generic)
    deriving newtype (Enum,Num,Real,Integral,Bounded,Default,FromJSON,ToJSON)

instance NFData TxId
instance Show TxId where
  show (TxId s) = show s
instance Pretty TxId where
  pretty (TxId s) = viaShow s
instance ToTerm TxId where toTerm = tLit . LInteger . fromIntegral
instance AsString TxId where asString = pack . show

instance Arbitrary TxId where
  arbitrary = TxId <$> arbitrary

data ExecutionMode =
    Transactional |
    Local
    deriving (Eq,Show)



-- | Shape of back-end methods: use MVar for state, run in IO.
type Method e a = MVar e -> IO a

-- | Fun-record type for Pact back-ends.
data PactDb e = PactDb {
    -- | Read a domain value at key, throwing an exception if not found.
    _readRow :: forall k v . (IsString k,FromJSON v) =>
                Domain k v -> k -> Method e (Maybe v)
    -- | Write a domain value at key. WriteType argument governs key behavior.
  , _writeRow :: forall k v . (AsString k,ToJSON v) =>
                 WriteType -> Domain k v -> k -> v -> Method e ()
    -- | Retrieve all keys for a domain, Key output guaranteed sorted.
  , _keys :: forall k v . (IsString k,AsString k) => Domain k v -> Method e [k]
    -- | Retrieve all transaction ids greater than supplied txid for table.
  , _txids ::  TableName -> TxId -> Method e [TxId]
    -- | Create a user table.
  , _createUserTable ::  TableName -> ModuleName -> Method e ()
    -- | Get module, keyset for user table.
  , _getUserTableInfo ::  TableName -> Method e ModuleName
    -- | Initiate transactional state. Returns txid for 'Transactional' mode
    -- or Nothing for 'Local' mode. If state already initiated, rollback and throw error.
  , _beginTx :: ExecutionMode -> Method e (Maybe TxId)
    -- | Conclude transactional state with commit.
    -- In transactional mode, commits backend to TxId.
    -- In Local mode, releases TxId for re-use.
    -- Returns all TxLogs.
  , _commitTx ::  Method e [TxLog LegacyValue]
    -- | Conclude transactional state with rollback.
    -- Safe to call at any time.
    -- Rollback all backend changes.
    -- Releases TxId for re-use.
  , _rollbackTx :: Method e ()
    -- | Get transaction log for table. TxLogs are expected to be user-visible format.
  , _getTxLog :: forall k v . (IsString k,FromJSON v) =>
                 Domain k v -> TxId -> Method e [TxLog v]
}
