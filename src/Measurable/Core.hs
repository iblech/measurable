{-# OPTIONS_GHC -Wall #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}

module Measurable.Core where

import Control.Applicative
import Control.Monad
import Control.Monad.Trans
import Data.Foldable (Foldable)
import qualified Data.Foldable as Foldable
import Data.Functor.Identity
import Data.Traversable
import Measurable.Util
import Numeric.Integration.TanhSinh

-- | A hand-rolled continuation type.  Exactly like the standard one you'd find
--   in @Control.Monad.Trans.Cont@, but without the supporting functions like
--   @callCC@, etc. included in that module.
newtype ContT r m a = ContT { runContT :: (a -> m r) -> m r }

type Cont r = ContT r Identity

runCont :: Cont r a -> (a -> r) -> r
runCont m k = runIdentity $ runContT m (Identity . k)

cont :: ((a -> r) -> r) -> Cont r a
cont f = ContT $ \c -> Identity $ f (runIdentity . c)

-- | A measure can be represented by nothing more than a continuation with a
--   restricted output type corresponding to the reals.
--
--   A @Functor@ instance implements pushforward or image measures - merely
--   @fmap@ a measurable function over a measure to create one.
--
--   An @Applicative@ instance adds measure convolution, subtraction, and
--   multiplication by enabling a @Num@ instance via 'liftA2' and an implicit
--   marginalizing effect.  A @Monad@ instance lumps the ability to create
--   measures from graphs of measures on top of that.
type Measure a    = Cont Double a
type MeasureT m a = ContT Double m a

instance Functor (ContT r m) where
  fmap f m = ContT $ \c -> runContT m (c . f)

instance Applicative (ContT r m) where
  pure x  = ContT ($ x)
  f <*> v = ContT $ \c ->
    runContT f $ \g ->
      runContT v (c . g)

instance Monad (ContT r m) where
  return x = ContT ($ x)
  m >>= k  = ContT $ \c ->
    runContT m $ \x ->
      runContT (k x) c

instance MonadTrans (ContT r) where
    lift m = ContT (m >>=)

-- | The 'integrate' function is just 'runCont' with its arguments reversed
--   in order to resemble the conventional mathematical notation, in which one
--   integrates a measurable function against a measure.
--
--   >>> let mu = fromSamples [-1, 0, 1]
--   >>> expectation mu
--   0.0
--   >>> expectation mu
--   1.0
integrate :: (a -> Double) -> Measure a -> Double
integrate = flip runCont

integrateT :: Applicative m => (a -> Double) -> MeasureT m a -> m Double
integrateT f = (`runContT` (pure . f))

instance (Applicative m, Num a) => Num (ContT Double m a) where
  (+)         = liftA2 (+)
  (-)         = liftA2 (-)
  (*)         = liftA2 (*)
  abs         = fmap id
  signum      = fmap signum
  fromInteger = pure . fromInteger

-- | Create a 'Measure' from a probability mass function and its support,
--   provided as a foldable container.
--
--   The requirement to supply the entire support is restrictive but necessary;
--   for approximations, consider using 'fromSamples' or
--   'fromSamplingFunction'.
--
--   >>> let mu = fromMassFunction (binomialPmf 10 0.2) [0..10]
--   >>> integrate fromIntegral mu
--   2.0
fromMassFunction
  :: (Functor f, Foldable f)
  => (a -> Double)
  -> f a
  -> Measure a
fromMassFunction f support = cont $ \g ->
  Foldable.sum $ (g /* f) <$> support

fromMassFunctionT :: (Applicative m, Traversable t)
  => (a -> Double)
  -> t a
  -> MeasureT m a
fromMassFunctionT f support = ContT $ \g ->
    fmap Foldable.sum . traverse (g //* (pure . f)) $ support

-- | Create a 'Measure' from a probability density function.
--
--   Note that queries on measures constructed with @fromDensityFunction@ are
--   subject to numerical error due to the underlying dependency on quadrature!
--
--   >>> let f x = 1 / (sqrt (2 * pi)) * exp (- (x ^ 2) / 2)
--   >>> let mu = fromDensityFunction f
--   >>> expectation mu
--   0.0
--   >>> variance mu
--   1.0000000000000002
fromDensityFunction :: (Double -> Double) -> Measure Double
fromDensityFunction d = cont $ \f -> quadratureTanhSinh $ f /* d where
  quadratureTanhSinh = result . last . everywhere trap

-- | Create a measure from a collection of observations.
--
--   Useful for creating general purpose empirical measures.
--
--   >>> let mu = fromSamples [(1, 2), (3, 4)]
--   >>> integrate (uncurry (+)) mu
--   5.0
fromSamples :: Foldable f => f a -> Measure a
fromSamples = cont . flip weightedAverage

fromSamplesT
  :: (Applicative m, Traversable f)
  => f a
  -> MeasureT m a
fromSamplesT = ContT . flip weightedAverageM

-- | Create a measure from a sampling function.  Runs the sampling function
--   the provided number of times and runs 'fromSamples' on the result.
fromSamplingFunction
  :: (Monad m, Applicative m)
  => (t -> m b)
  -> Int
  -> t
  -> MeasureT m b
fromSamplingFunction f n g = (lift $ replicateM n (f g)) >>= fromSamplesT

-- | A simple alias for @fmap@.
push :: (a -> b) -> Measure a -> Measure b
push = fmap

pushT :: Monad m => (a -> b) -> MeasureT m a -> MeasureT m b
pushT = fmap

-- | The expectation of a measure is typically understood to be its expected
--   value, which is found by integrating it against the identity function.
expectation :: Measure Double -> Double
expectation = integrate id

expectationT :: Applicative m => MeasureT m Double -> m Double
expectationT = integrateT id

-- | The variance of a measure, as per the usual formula
--   @var X = E^2 X - EX^2@.
variance :: Measure Double -> Double
variance mu = integrate (^ 2) mu - expectation mu ^ 2

varianceT :: Applicative m => MeasureT m Double -> m Double
varianceT mu = liftA2 (-) (integrateT (^ 2) mu) ((^ 2) <$> expectationT mu)

-- | The @nth@ raw moment of a 'Measure'.
rawMoment :: Int -> Measure Double -> Double
rawMoment n = integrate (^ n)

rawMomentT :: (Applicative m, Monad m) => Int -> MeasureT m Double -> m Double
rawMomentT n = integrateT (^ n)

-- | All raw moments of a 'Measure'.
rawMoments :: Measure Double -> [Double]
rawMoments mu = (`rawMoment` mu) <$> [1..]

rawMomentsT :: (Applicative m, Monad m) => MeasureT m Double -> Int -> m [Double]
rawMomentsT mu n = traverse (`rawMomentT` mu) $ take n [1..]

-- | The @nth@ central moment of a 'Measure'.
centralMoment :: Int -> Measure Double -> Double
centralMoment n mu = integrate (\x -> (x - rm) ^ n) $ mu
  where rm = rawMoment 1 mu

centralMomentT :: (Applicative m, Monad m) => Int -> MeasureT m Double -> m Double
centralMomentT n mu = integrateT (^ n) $ do
  rm <- lift $ rawMomentT 1 mu
  (subtract rm) <$> mu

-- | All central moments of a 'Measure'.
centralMoments :: Measure Double -> [Double]
centralMoments mu = (`centralMoment` mu) <$> [1..]

centralMomentsT :: (Applicative m, Monad m) => MeasureT m Double -> Int -> m [Double]
centralMomentsT mu n = traverse (`centralMomentT` mu) $ take n [1..]

-- | The moment generating function corresponding to a 'Measure'.
--
--   >>> let mu = fromSamples [1..10]
--   >>> let mgfMu = momentGeneratingFunction mu
--   >>> fmap mgfMu [0, 0.5, 1]
--   [1.0,37.4649671547254,3484.377384533132]
momentGeneratingFunction :: Measure Double -> Double -> Double
momentGeneratingFunction mu t = integrate (exp . (* t)) mu

-- | The cumulant generating function corresponding to a 'Measure'.
--
--   >>> let mu = fromSamples [1..10]
--   >>> let cgfMu = cumulantGeneratingFunction mu
--   >>> fmap cgfMu [0, 0.5, 1]
--   [0.0,3.6234062871236543,8.156044651432666]
cumulantGeneratingFunction :: Measure Double -> Double -> Double
cumulantGeneratingFunction mu = log . momentGeneratingFunction mu

-- | Calculates the volume of a 'Measure' over its entire space.  Trivially 1
--   for any probability measure.
--
--   >>> let mu = fromSamples [1..10]
--   >>> volume mu
--   1.0
volume :: Measure a -> Double
volume = integrate $ const 1

volumeT :: Applicative m => MeasureT m a -> m Double
volumeT = integrateT $ const 1

-- | The cumulative distribution function corresponding to a 'Measure'
--
--   >>> let mu = fromSamples [1..10]
--   >>> let cdfMu = cdf mu
--   >>> fmap cdfMu [0..10]
--   [0.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0]
cdf :: Measure Double -> Double -> Double
cdf mu x = expectation $ negativeInfinity `to` x <$> mu

cdfT :: Applicative m => MeasureT m Double -> Double -> m Double
cdfT mu x = expectationT $ negativeInfinity `to` x <$> mu

-- | A helpful utility for calculating the volume of a region in a measure
--   space.
--
--   >>> let mu = fromSamples [1..10]
--   >>> integrate (2 `to` 8) mu
--   0.7
to :: (Num a, Ord a) => a -> a -> a -> a
to a b x
  | x >= a && x <= b = 1
  | otherwise        = 0

-- | An analogue of 'to' for measures defined over non-ordered domains.
--
--   >>> data Group = A | B | C deriving Eq
--   >>> let mu = fromSamples [A, A, A, B, A, B, C]
--   >>> integrate (containing [B]) mu
--   0.2857142857142857
--   >>> integrate (containing [A,C]) mu
--   0.7142857142857143
--   >>> integrate (containing [A,B,C]) mu
--   1.0
containing :: (Num a, Eq b) => [b] -> b -> a
containing xs x
  | x `elem` xs = 1
  | otherwise   = 0

