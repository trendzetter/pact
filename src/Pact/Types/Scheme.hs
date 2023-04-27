{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies, GADTs, DataKinds #-}


module Pact.Types.Scheme
  ( PPKScheme(..)
  , defPPKScheme
  , SPPKScheme(..)
  ) where



import GHC.Generics
import Control.DeepSeq
import Data.Kind (Type)
import Data.Serialize
import Data.Aeson
import Test.QuickCheck
import qualified Data.Text as T

import Pact.Types.Util (ParseText(..))

import qualified Pact.JSON.Encode as J


--------- PPKSCHEME DATA TYPE ---------

data PPKScheme = ED25519 | WebAuthn
  deriving (Show, Eq, Ord, Generic)

instance NFData PPKScheme
instance Serialize PPKScheme

instance ToJSON PPKScheme where
  toJSON ED25519 = "ED25519"
  toJSON WebAuthn = "WebAuthn"

  toEncoding ED25519 = toEncoding @T.Text "ED25519"
  toEncoding WebAuthn = toEncoding @T.Text "WebAuthn"
  {-# INLINE toJSON #-}
  {-# INLINE toEncoding #-}

instance FromJSON PPKScheme where
  parseJSON = withText "PPKScheme" parseText
  {-# INLINE parseJSON #-}

instance ParseText PPKScheme where
  parseText s = case s of
    "ED25519" -> return ED25519
    "WebAuthn" -> return WebAuthn
    _ -> fail $ "Unsupported PPKScheme: " ++ show s
  {-# INLINE parseText #-}

instance Arbitrary PPKScheme where
  arbitrary = elements [ED25519 , WebAuthn]

instance J.Encode PPKScheme where
  build ED25519 = J.text "ED25519"
  build WebAuthn = J.text "WebAuthn"
  {-# INLINE build #-}


defPPKScheme :: PPKScheme
defPPKScheme = ED25519


-- Run-time witness to PPKScheme kind.

data SPPKScheme :: PPKScheme -> Type where
  SED25519 :: SPPKScheme 'ED25519
  SWebAuthn :: SPPKScheme 'WebAuthn
instance Show (SPPKScheme a) where
  show SED25519 = show ED25519
  show SWebAuthn = show WebAuthn
