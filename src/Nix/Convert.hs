{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

{-# OPTIONS_GHC -Wno-missing-signatures #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

-- | Although there are a lot of instances in this file, really it's just a
--   combinatorial explosion of the following combinations:
--
--   - Several Haskell types being converted to/from Nix wrappers
--   - Several types of Nix wrappers
--   - Whether to be shallow or deep while unwrapping

module Nix.Convert where

import           Control.Monad.Free
import           Data.ByteString
import           Data.Fix
import qualified Data.HashMap.Lazy             as M
import           Data.Maybe
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import           Data.Text.Encoding             ( encodeUtf8
                                                , decodeUtf8
                                                )
import           Nix.Atoms
import           Nix.Effects
import           Nix.Expr.Types
import           Nix.Expr.Types.Annotated
import           Nix.Frames
import           Nix.String
import           Nix.Value
import           Nix.Value.Monad
import           Nix.Utils

newtype Deeper a = Deeper { getDeeper :: a }

{-

IMPORTANT NOTE

We used to have Text instances of FromValue, ToValue, FromNix, and ToNix.
However, we're removing these instances because they are dangerous due to the
fact that they hide the way string contexts are handled. It's better to have to
explicitly handle string context in a way that is appropriate for the situation.

Do not add these instances back!

-}

{-----------------------------------------------------------------------
   FromValue
 -----------------------------------------------------------------------}

class FromValue a m v where
    fromValue    :: v -> m a
    fromValueMay :: v -> m (Maybe a)

type Convertible e t f m = (Framed e m, MonadDataErrorContext t f m)

instance ( Convertible e t f m
         , MonadValue (NValueNF t f m) m
         , FromValue a m (NValue' t f m (NValueNF t f m))
         )
  => FromValue a m (NValueNF t f m) where
  fromValueMay = flip demand $ \(Fix v) -> fromValueMay v
  fromValue    = flip demand $ \(Fix v) -> fromValue v

instance ( Convertible e t f m
         , MonadValue (NValue t f m) m
         , FromValue a m (NValue' t f m (NValue t f m))
         )
  => FromValue a m (NValue t f m) where
  fromValueMay = flip demand $ \case
    Pure _ -> pure Nothing
    Free v -> fromValueMay v
  fromValue    = flip demand $ \case
    Pure t -> throwError $ ForcingThunk @t @f @m t
    Free v -> fromValue v

instance ( Convertible e t f m
         , MonadValue (NValueNF t f m) m
         , FromValue a m (Deeper (NValue' t f m (NValueNF t f m)))
         )
  => FromValue a m (Deeper (NValueNF t f m)) where
  fromValueMay (Deeper v) = demand v $ \(Fix v) -> fromValueMay (Deeper v)
  fromValue (Deeper v)    = demand v $ \(Fix v) -> fromValue (Deeper v)

instance ( Convertible e t f m
         , MonadValue (NValue t f m) m
         , FromValue a m (Deeper (NValue' t f m (NValue t f m)))
         )
  => FromValue a m (Deeper (NValue t f m)) where
  fromValueMay (Deeper v) = demand v $ \case
    Pure _ -> pure Nothing
    Free v -> fromValueMay (Deeper v)
  fromValue (Deeper v)   = demand v $ \case
    Pure t -> throwError $ ForcingThunk @t @f @m t
    Free v -> fromValue (Deeper v)

instance (Convertible e t f m, Show r) => FromValue () m (NValue' t f m r) where
  fromValueMay = \case
    NVConstant' NNull -> pure $ Just ()
    _                 -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TNull v

instance (Convertible e t f m, Show r) => FromValue Bool m (NValue' t f m r) where
  fromValueMay = \case
    NVConstant' (NBool b) -> pure $ Just b
    _                     -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TBool v

instance (Convertible e t f m, Show r) => FromValue Int m (NValue' t f m r) where
  fromValueMay = \case
    NVConstant' (NInt b) -> pure $ Just (fromInteger b)
    _                    -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TInt v

instance (Convertible e t f m, Show r) => FromValue Integer m (NValue' t f m r) where
  fromValueMay = \case
    NVConstant' (NInt b) -> pure $ Just b
    _                    -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TInt v

instance (Convertible e t f m, Show r) => FromValue Float m (NValue' t f m r) where
  fromValueMay = \case
    NVConstant' (NFloat b) -> pure $ Just b
    NVConstant' (NInt   i) -> pure $ Just (fromInteger i)
    _                      -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TFloat v

instance (Convertible e t f m, Show r, MonadEffects t f m,
          FromValue NixString m r)
      => FromValue NixString m (NValue' t f m r) where
  fromValueMay = \case
    NVStr' ns -> pure $ Just ns
    NVPath' p ->
      Just
        .   hackyMakeNixStringWithoutContext
        .   Text.pack
        .   unStorePath
        <$> addPath p
    NVSet' s _ -> case M.lookup "outPath" s of
      Nothing -> pure Nothing
      Just p  -> fromValueMay p
    _ -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation (TString NoContext) v

instance (Convertible e t f m, Show r)
      => FromValue ByteString m (NValue' t f m r) where
  fromValueMay = \case
    NVStr' ns -> pure $ encodeUtf8 <$> hackyGetStringNoContext ns
    _        -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation (TString NoContext) v

newtype Path = Path { getPath :: FilePath }
    deriving Show

instance (Convertible e t f m, Show r, FromValue Path m r)
  => FromValue Path m (NValue' t f m r) where
  fromValueMay = \case
    NVPath' p  -> pure $ Just (Path p)
    NVStr'  ns -> pure $ Path . Text.unpack <$> hackyGetStringNoContext ns
    NVSet' s _ -> case M.lookup "outPath" s of
      Nothing -> pure Nothing
      Just p  -> fromValueMay @Path p
    _ -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TPath v

instance (Convertible e t f m, Show r)
  => FromValue [r] m (NValue' t f m r) where
  fromValueMay = \case
    NVList' l -> pure $ Just l
    _         -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TList v

instance (Convertible e t f m, Show r, FromValue a m r)
  => FromValue [a] m (Deeper (NValue' t f m r)) where
  fromValueMay = \case
    Deeper (NVList' l) -> sequence <$> traverse fromValueMay l
    _                  -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TList (getDeeper v)

instance (Convertible e t f m, Show r)
      => FromValue (AttrSet r) m (NValue' t f m r) where
  fromValueMay = \case
    NVSet' s _ -> pure $ Just s
    _          -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TSet v

instance (Convertible e t f m, Show r, FromValue a m r)
      => FromValue (AttrSet a) m (Deeper (NValue' t f m r)) where
  fromValueMay = \case
    Deeper (NVSet' s _) -> sequence <$> traverse fromValueMay s
    _                   -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TSet (getDeeper v)

instance (Convertible e t f m, Show r)
      => FromValue (AttrSet r, AttrSet SourcePos) m (NValue' t f m r) where
  fromValueMay = \case
    NVSet' s p -> pure $ Just (s, p)
    _          -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TSet v

instance (Convertible e t f m, Show r, FromValue a m r)
      => FromValue (AttrSet a, AttrSet SourcePos) m (Deeper (NValue' t f m r)) where
  fromValueMay = \case
    Deeper (NVSet' s p) -> fmap (,p) <$> sequence <$> traverse fromValueMay s
    _                   -> pure Nothing
  fromValue v = fromValueMay v >>= \case
    Just b -> pure b
    _      -> throwError $ Expectation TSet (getDeeper v)

instance (Convertible e t f m, FromValue a m r) => FromValue a m (Deeper r) where
  fromValueMay = fromValueMay . getDeeper
  fromValue    = fromValue . getDeeper

{-----------------------------------------------------------------------
   ToValue
 -----------------------------------------------------------------------}

class ToValue a m v where
    toValue :: a -> m v

instance Applicative m => ToValue (NValueNF t f m) m (NValueNF t f m) where
  toValue = pure

instance Applicative m => ToValue (NValue t f m) m (NValue t f m) where
  toValue = pure

instance (Convertible e t f m, ToValue a m (NValue' t f m (NValueNF t f m)))
  => ToValue a m (NValueNF t f m) where
  toValue = fmap Fix . toValue

instance (Convertible e t f m, ToValue a m (NValue' t f m (NValue t f m)))
  => ToValue a m (NValue t f m) where
  toValue = fmap Free . toValue

instance Convertible e t f m => ToValue () m (NValue' t f m r) where
  toValue _ = pure . nvConstant' $ NNull

instance Convertible e t f m => ToValue Bool m (NValue' t f m r) where
  toValue = pure . nvConstant' . NBool

instance Convertible e t f m => ToValue Int m (NValue' t f m r) where
  toValue = pure . nvConstant' . NInt . toInteger

instance Convertible e t f m => ToValue Integer m (NValue' t f m r) where
  toValue = pure . nvConstant' . NInt

instance Convertible e t f m => ToValue Float m (NValue' t f m r) where
  toValue = pure . nvConstant' . NFloat

instance Convertible e t f m => ToValue NixString m (NValue' t f m r) where
  toValue = pure . nvStr'

instance Convertible e t f m => ToValue ByteString m (NValue' t f m r) where
  toValue = pure . nvStr' . hackyMakeNixStringWithoutContext . decodeUtf8

instance Convertible e t f m => ToValue Path m (NValue' t f m r) where
  toValue = pure . nvPath' . getPath

instance Convertible e t f m => ToValue StorePath m (NValue' t f m r) where
  toValue = toValue . Path . unStorePath

instance ( Convertible e t f m
         , ToValue NixString m r
         , ToValue Int m r
         )
  => ToValue SourcePos m (NValue' t f m r) where
  toValue (SourcePos f l c) = do
    f' <- toValue (principledMakeNixStringWithoutContext (Text.pack f))
    l' <- toValue (unPos l)
    c' <- toValue (unPos c)
    let pos = M.fromList
          [ ("file" :: Text, f')
          , ("line"       , l')
          , ("column"     , c')
          ]
    pure $ nvSet' pos mempty

-- | With 'ToValue', we can always act recursively
instance (Convertible e t f m, ToValue a m r)
  => ToValue [a] m (NValue' t f m r) where
  toValue = fmap nvList' . traverse toValue

instance (Convertible e t f m, ToValue a m r)
  => ToValue (AttrSet a) m (NValue' t f m r) where
  toValue s = nvSet' <$> traverse toValue s <*> pure mempty

instance (Convertible e t f m, ToValue a m r)
  => ToValue (AttrSet a, AttrSet SourcePos) m (NValue' t f m r) where
  toValue (s, p) = nvSet' <$> traverse toValue s <*> pure p

instance ( MonadValue (NValue t f m) m
         , MonadDataErrorContext t f m
         , Framed e m
         , ToValue NixString m r
         , ToValue Bool m r
         , ToValue [r] m r
         )
    => ToValue NixLikeContextValue m (NValue' t f m r) where
  toValue nlcv = do
    path <- if nlcvPath nlcv then Just <$> toValue True else return Nothing
    allOutputs <- if nlcvAllOutputs nlcv
      then Just <$> toValue True
      else return Nothing
    outputs <- do
      let outputs =
            fmap principledMakeNixStringWithoutContext $ nlcvOutputs nlcv
      ts :: [r] <- traverse toValue outputs
      case ts of
        [] -> return Nothing
        _  -> Just <$> toValue ts
    pure $ flip nvSet' M.empty $ M.fromList $ catMaybes
      [ (\p  -> ("path",       p))  <$> path
      , (\ao -> ("allOutputs", ao)) <$> allOutputs
      , (\os -> ("outputs",    os)) <$> outputs
      ]

instance Convertible e t f m => ToValue () m (NExprF r) where
  toValue _ = pure . NConstant $ NNull

instance Convertible e t f m => ToValue Bool m (NExprF r) where
  toValue = pure . NConstant . NBool
