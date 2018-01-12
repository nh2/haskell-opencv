{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module OpenCV.Calib3d
    ( FundamentalMatMethod(..)
    , FindHomographyMethod(..)
    , FindHomographyParams(..)
    , WhichImage(..)
    -- , calibrateCamera
    , findFundamentalMat
    , findHomography
    , computeCorrespondEpilines

    , SolvePnPMethod(..)
    , solvePnP
    ) where

import "base" Data.Int
import "base" Data.Word
import "base" Foreign.C.Types
import "base" Foreign.Marshal.Utils ( fromBool )
import qualified "inline-c" Language.C.Inline as C
import qualified "inline-c-cpp" Language.C.Inline.Cpp as C
import "data-default" Data.Default
import "this" OpenCV.Internal.C.Inline ( openCvCtx )
import "this" OpenCV.Internal.C.Types
import "this" OpenCV.Internal.Calib3d.Constants
import "this" OpenCV.Core.Types
import "this" OpenCV.Internal.Core.Types
import "this" OpenCV.Internal.Core.Types.Mat
import "this" OpenCV.Internal.Exception
import "this" OpenCV.TypeLevel
import "transformers" Control.Monad.Trans.Except
import qualified "vector" Data.Vector as V

--------------------------------------------------------------------------------

C.context openCvCtx

C.include "opencv2/core.hpp"
C.include "opencv2/calib3d.hpp"
C.using "namespace cv"

--------------------------------------------------------------------------------
-- Types

data FundamentalMatMethod
   = FM_7Point
   | FM_8Point
   | FM_Ransac !(Maybe Double) !(Maybe Double)
   | FM_Lmeds  !(Maybe Double)
     deriving (Show, Eq)

marshalFundamentalMatMethod :: FundamentalMatMethod -> (Int32, CDouble, CDouble)
marshalFundamentalMatMethod = \case
    FM_7Point       -> (c'CV_FM_7POINT, 0, 0)
    FM_8Point       -> (c'CV_FM_8POINT, 0, 0)
    FM_Ransac p1 p2 -> (c'CV_FM_RANSAC, maybe 3 realToFrac p1, maybe 0.99 realToFrac p2)
    FM_Lmeds     p2 -> (c'CV_FM_LMEDS, 0, maybe 0.99 realToFrac p2)

data WhichImage = Image1 | Image2 deriving (Show, Eq)

marshalWhichImage :: WhichImage -> Int32
marshalWhichImage = \case
    Image1 -> 1
    Image2 -> 2

data FindHomographyMethod
   = FindHomographyMethod_0
     -- ^ A regular method using all the points.
   | FindHomographyMethod_RANSAC
     -- ^ RANSAC-based robust method.
   | FindHomographyMethod_LMEDS
     -- ^ Least-Median robust method.
   | FindHomographyMethod_RHO
     -- ^ PROSAC-based robust method.
     deriving (Show)

marshalFindHomographyMethod :: FindHomographyMethod -> Int32
marshalFindHomographyMethod = \case
    FindHomographyMethod_0      -> 0
    FindHomographyMethod_RANSAC -> c'RANSAC
    FindHomographyMethod_LMEDS  -> c'LMEDS
    FindHomographyMethod_RHO    -> c'RHO

--------------------------------------------------------------------------------

-- {- |
-- <http://docs.opencv.org/3.0-last-rst/modules/calib3d/doc/camera_calibration_and_3d_reconstruction.html#calibratecamera OpenCV Sphinx doc>
-- -}
-- calibrateCamera
--     :: ( ToSize2i imageSize
--        , camMat ~ Mat (ShapeT [3, 3]) ('S 1) ('S Double)
--        )
--      . V.Vector () -- combine objectPoints and imagePoints
--     -> imageSize
--     -> camMat
--     -> flags
--     -> criteria
--     -> (camMat, distCoeffs, rvecs, tvecs)
-- calibrateCamera = _todo

{- | Calculates a fundamental matrix from the corresponding points in two images

The minimum number of points required depends on the 'FundamentalMatMethod'.

 * 'FM_7Point': @N == 7@
 * 'FM_8Point': @N >= 8@
 * 'FM_Ransac': @N >= 15@
 * 'FM_Lmeds': @N >= 8@

With 7 points the 'FM_7Point' method is used, despite the given method.

With more than 7 points the 'FM_7Point' method will be replaced by the
'FM_8Point' method.

Between 7 and 15 points the 'FM_Ransac' method will be replaced by the
'FM_Lmeds' method.

With the 'FM_7Point' method and with 7 points the result can contain up to 3
matrices, resulting in either 3, 6 or 9 rows. This is why the number of
resulting rows in tagged as 'D'ynamic. For all other methods the result always
contains 3 rows.

<http://docs.opencv.org/3.0-last-rst/modules/calib3d/doc/camera_calibration_and_3d_reconstruction.html#findfundamentalmat OpenCV Sphinx doc>
-}
findFundamentalMat
    :: (IsPoint2 point2 CDouble)
    => V.Vector (point2 CDouble) -- ^ Points from the first image.
    -> V.Vector (point2 CDouble) -- ^ Points from the second image.
    -> FundamentalMatMethod
    -> CvExcept ( Maybe ( Mat ('S '[ 'D, 'S 3 ]) ('S 1) ('S Double)
                        , Mat ('S '[ 'D, 'D   ]) ('S 1) ('S Word8 )
                        )
                )
findFundamentalMat pts1 pts2 method = do
    (fm, pointMask) <- c'findFundamentalMat
    -- If the c++ function can't find a fundamental matrix it will
    -- return an empty matrix. We check for this case by trying to
    -- coerce the result to the desired type.
    catchE (Just . (, unsafeCoerceMat pointMask) <$> coerceMat fm)
           (\case CoerceMatError _msgs -> pure Nothing
                  otherError -> throwE otherError
           )
  where
    c'findFundamentalMat = unsafeWrapException $ do
      fm        <- newEmptyMat
      pointMask <- newEmptyMat
      handleCvException (pure (fm, pointMask)) $
        withPtr fm $ \fmPtr ->
        withPtr pointMask $ \pointMaskPtr ->
        withArrayPtr (V.map toPoint pts1) $ \pts1Ptr ->
        withArrayPtr (V.map toPoint pts2) $ \pts2Ptr ->
          [cvExcept|
            cv::_InputArray pts1 = cv::_InputArray($(Point2d * pts1Ptr), $(int32_t c'numPts1));
            cv::_InputArray pts2 = cv::_InputArray($(Point2d * pts2Ptr), $(int32_t c'numPts2));
            *$(Mat * fmPtr) =
              cv::findFundamentalMat
              ( pts1
              , pts2
              , $(int32_t c'method)
              , $(double c'p1)
              , $(double c'p2)
              , *$(Mat * pointMaskPtr)
              );
          |]

    c'numPts1 = fromIntegral $ V.length pts1
    c'numPts2 = fromIntegral $ V.length pts2
    (c'method, c'p1, c'p2) = marshalFundamentalMatMethod method

data FindHomographyParams
   = FindHomographyParams
     { fhpMethod                :: !FindHomographyMethod
     , fhpRansacReprojThreshold :: !Double
     , fhpMaxIters              :: !Int
     , fhpConfidence            :: !Double
     } deriving (Show)

instance Default FindHomographyParams where
    def = FindHomographyParams
          { fhpMethod                = FindHomographyMethod_0
          , fhpRansacReprojThreshold = 3
          , fhpMaxIters              = 2000
          , fhpConfidence            = 0.995
          }

findHomography
    :: (IsPoint2 point2 CDouble)
    => V.Vector (point2 CDouble) -- ^ Points from the first image.
    -> V.Vector (point2 CDouble) -- ^ Points from the second image.
    -> FindHomographyParams
    -> CvExcept ( Maybe ( Mat ('S '[ 'S 3, 'S 3 ]) ('S 1) ('S Double)
                        , Mat ('S '[ 'D, 'D   ]) ('S 1) ('S Word8 )
                        )
                )
findHomography srcPoints dstPoints fhp = do
    (fm, pointMask) <- c'findHomography
    -- If the c++ function can't find a fundamental matrix it will
    -- return an empty matrix. We check for this case by trying to
    -- coerce the result to the desired type.
    catchE (Just . (, unsafeCoerceMat pointMask) <$> coerceMat fm)
           (\case CoerceMatError _msgs -> pure Nothing
                  otherError           -> throwE otherError
           )
  where
    c'findHomography = unsafeWrapException $ do
      fm        <- newEmptyMat
      pointMask <- newEmptyMat
      handleCvException (pure (fm, pointMask)) $
        withPtr fm $ \fmPtr ->
        withPtr pointMask $ \pointMaskPtr ->
        withArrayPtr (V.map toPoint srcPoints) $ \srcPtr ->
        withArrayPtr (V.map toPoint dstPoints) $ \dstPtr ->
          [cvExcept|
            cv::_InputArray srcPts = cv::_InputArray($(Point2d * srcPtr), $(int32_t c'numSrcPts));
            cv::_InputArray dstPts = cv::_InputArray($(Point2d * dstPtr), $(int32_t c'numDstPts));
            *$(Mat * fmPtr) =
              cv::findHomography
                  ( srcPts
                  , dstPts
                  , $(int32_t c'method)
                  , $(double c'ransacReprojThreshold)
                  , *$(Mat * pointMaskPtr)
                  , $(int32_t c'maxIters)
                  , $(double c'confidence)
                  );
          |]
    c'numSrcPts = fromIntegral $ V.length srcPoints
    c'numDstPts = fromIntegral $ V.length dstPoints
    c'method = marshalFindHomographyMethod $ fhpMethod fhp
    c'ransacReprojThreshold = realToFrac $ fhpRansacReprojThreshold fhp
    c'maxIters = fromIntegral $ fhpMaxIters fhp
    c'confidence = realToFrac $ fhpConfidence fhp

{- | For points in an image of a stereo pair, computes the corresponding epilines in the other image

<http://docs.opencv.org/3.0-last-rst/modules/calib3d/doc/camera_calibration_and_3d_reconstruction.html#computecorrespondepilines OpenCV Sphinx doc>
-}
computeCorrespondEpilines
    :: (IsPoint2 point2 CDouble)
    => V.Vector (point2 CDouble) -- ^ Points.
    -> WhichImage -- ^ Image which contains the points.
    -> Mat (ShapeT [3, 3]) ('S 1) ('S Double) -- ^ Fundamental matrix.
    -> CvExcept (Mat ('S ['D, 'S 1]) ('S 3) ('S Double))
computeCorrespondEpilines points whichImage fm = unsafeWrapException $ do
    epilines <- newEmptyMat
    handleCvException (pure $ unsafeCoerceMat epilines) $
      withArrayPtr (V.map toPoint points) $ \pointsPtr ->
      withPtr fm       $ \fmPtr       ->
      withPtr epilines $ \epilinesPtr -> do
        -- Destroy type information about the pointsPtr. We wan't to generate
        -- C++ code that works for any type of point. Specifically Point2f and
        -- Point2d.
        [cvExcept|
          cv::_InputArray points =
            cv::_InputArray( $(Point2d * pointsPtr)
                           , $(int32_t c'numPoints)
                           );
          cv::computeCorrespondEpilines
          ( points
          , $(int32_t c'whichImage)
          , *$(Mat * fmPtr)
          , *$(Mat * epilinesPtr)
          );
        |]
  where
    c'numPoints = fromIntegral $ V.length points
    c'whichImage = marshalWhichImage whichImage

data SolvePnPMethod
   = SolvePnP_Iterative !Bool
   | SolvePnP_P3P
   | SolvePnP_AP3P
   | SolvePnP_EPNP
   | SolvePnP_DLS
   | SolvePnP_UPNP

marshalSolvePnPMethod :: SolvePnPMethod -> (Int32, Int32)
marshalSolvePnPMethod = \case
    SolvePnP_Iterative useExtrinsicGuess
                  -> (c'SOLVEPNP_ITERATIVE, fromBool useExtrinsicGuess)
    SolvePnP_P3P  -> (c'SOLVEPNP_P3P , fromBool False)
    SolvePnP_AP3P -> (c'SOLVEPNP_AP3P, fromBool False)
    SolvePnP_EPNP -> (c'SOLVEPNP_EPNP, fromBool False)
    SolvePnP_DLS  -> (c'SOLVEPNP_DLS , fromBool False)
    SolvePnP_UPNP -> (c'SOLVEPNP_UPNP, fromBool False)

{- | Finds an object pose from 3D-2D point correspondences.

Parameters:

  [@objectImageMatches@]: Correspondences between object coordinate space (3D)
    and image points (2D).

  [@cameraMatrix@]: Input camera matrix
    \[
    A =
    \begin{bmatrix}
    f_x & 0   & c_x \\
    0   & f_y & c_y \\
    0   & 0   & 1
    \end{bmatrix}
    \]

  [@distCoeffs@]: Input distortion coefficients
    \( \left ( k_1, k_2, p_1, p_2[, k_3[, k_4, k_5, k_6 [, s_1, s_2, s_3, s_4[, \tau_x, \tau_y ] ] ] ] \right ) \)
    of 4, 5, 8, 12 or 14 elements. If not given, the zero distortion
    coefficients are assumed.

In case of success the algorithm outputs 3 values:

  [@rvec@]: Output rotation vector that, together with __tvec__, brings points
    from the model coordinate system to the camera coordinate system.

  [@tvec@]: Output translation vector.

  [@cameraMatrix@]: Output camera matrix. In most cases a copy of the input
    camera matrix.  With the 'SolvePnP_UPNP' method the \(f_x\) and \(f_y\)
    parameters will be estimated.

The function estimates the object pose given a set of object points, their
corresponding image projections, as well as the camera matrix and the distortion
coefficients, see the figure below (more precisely, the X-axis of the camera
frame is pointing to the right, the Y-axis downward and the Z-axis forward).

<<data/solvepnp.jpg solvepnp explanatory figure>>

Points expressed in the world frame \(\bf{X_w}\) are projected into the image
plane \([u,v]\) using the perspective projection model \(\bf{\Pi}\) and the
camera intrinsic parameters matrix \(\bf{A}\):

\[
  \begin{align*}
  \begin{bmatrix}
  u \\
  v \\
  1
  \end{bmatrix} &=
  \bf{A} \hspace{0.1em} \Pi \hspace{0.2em} ^{c}\bf{M}_w
  \begin{bmatrix}
  X_{w} \\
  Y_{w} \\
  Z_{w} \\
  1
  \end{bmatrix} \\
  \begin{bmatrix}
  u \\
  v \\
  1
  \end{bmatrix} &=
  \begin{bmatrix}
  f_x & 0   & c_x \\
  0   & f_y & c_y \\
  0   & 0   & 1
  \end{bmatrix}
  \begin{bmatrix}
  1 & 0 & 0 & 0 \\
  0 & 1 & 0 & 0 \\
  0 & 0 & 1 & 0
  \end{bmatrix}
  \begin{bmatrix}
  r_{11} & r_{12} & r_{13} & t_x \\
  r_{21} & r_{22} & r_{23} & t_y \\
  r_{31} & r_{32} & r_{33} & t_z \\
  0 & 0 & 0 & 1
  \end{bmatrix}
  \begin{bmatrix}
  X_{w} \\
  Y_{w} \\
  Z_{w} \\
  1
  \end{bmatrix}
  \end{align*}
\]

The estimated pose is thus the rotation (__rvec__) and the translation
(__tvec__) vectors that allow to transform a 3D point expressed in the world
frame into the camera frame:

\[
  \begin{align*}
  \begin{bmatrix}
  X_c \\
  Y_c \\
  Z_c \\
  1
  \end{bmatrix} &=
  \hspace{0.2em} ^{c}\bf{M}_w
  \begin{bmatrix}
  X_{w} \\
  Y_{w} \\
  Z_{w} \\
  1
  \end{bmatrix} \\
  \begin{bmatrix}
  X_c \\
  Y_c \\
  Z_c \\
  1
  \end{bmatrix} &=
  \begin{bmatrix}
  r_{11} & r_{12} & r_{13} & t_x \\
  r_{21} & r_{22} & r_{23} & t_y \\
  r_{31} & r_{32} & r_{33} & t_z \\
  0      & 0      & 0      & 1
  \end{bmatrix}
  \begin{bmatrix}
  X_{w} \\
  Y_{w} \\
  Z_{w} \\
  1
  \end{bmatrix}
  \end{align*}
\]

-}
solvePnP
    :: forall point3 point2 distCoeffs
     . ( IsPoint3 point3 CDouble
       , IsPoint2 point2 CDouble
       , ToMat distCoeffs
       , MatShape distCoeffs `In` '[ 'S '[ 'S  4, 'S 1 ]
                                   , 'S '[ 'S  5, 'S 1 ]
                                   , 'S '[ 'S  8, 'S 1 ]
                                   , 'S '[ 'S 12, 'S 1 ]
                                   , 'S '[ 'S 14, 'S 1 ]
                                   ]
       )
    => V.Vector (point3 CDouble, point2 CDouble) -- ^ 3D-2D point correspondences.
    -> Mat (ShapeT '[3, 3]) ('S 1) ('S Double) -- ^ Camera matrix.
    -> Maybe distCoeffs -- ^ Distortion coefficients.
    -> SolvePnPMethod
    -> CvExcept
       ( Mat (ShapeT '[3, 1]) ('S 1) ('S Double) -- rotation vector
       , Mat (ShapeT '[3, 1]) ('S 1) ('S Double) -- translation vector
       , Mat (ShapeT '[3, 3]) ('S 1) ('S Double) -- output camera matrix
       )
solvePnP objectImageMatches cameraMatrix mbDistCoeffs method = unsafeWrapException $ do
    rvec <- newEmptyMat
    tvec <- newEmptyMat
    let cameraMatrixOut = cloneMat cameraMatrix
    handleCvException (pure ( unsafeCoerceMat rvec
                            , unsafeCoerceMat tvec
                            , cameraMatrixOut
                            )) $
      withArrayPtr objectPoints $ \objectPoinstPtr ->
      withArrayPtr imagePoints $ \imagePointsPtr ->
      withPtr cameraMatrixOut $ \cameraMatrixOutPtr ->
      withPtr (toMat <$> mbDistCoeffs) $ \distCoeffsPtr ->
      withPtr rvec $ \rvecPtr ->
      withPtr tvec $ \tvecPtr ->
        [cvExcept|
          cv::_InputArray objectPoints =
            cv::_InputArray( $(Point3d * objectPoinstPtr)
                           , $(int32_t c'numPoints)
                           );
          cv::_InputArray imagePoints =
            cv::_InputArray( $(Point2d * imagePointsPtr)
                           , $(int32_t c'numPoints)
                           );
          cv::Mat * distCoeffsPtr = $(Mat * distCoeffsPtr);
          bool retval =
            cv::solvePnP
            ( objectPoints
            , imagePoints
            , *$(Mat * cameraMatrixOutPtr)
            , distCoeffsPtr
              ? cv::_InputArray(*distCoeffsPtr)
              : cv::_InputArray(cv::noArray())
            , *$(Mat * rvecPtr)
            , *$(Mat * tvecPtr)
            , $(int32_t useExtrinsicGuess)
            , $(int32_t methodFlag)
            );
        |]
  where
    (methodFlag, useExtrinsicGuess) = marshalSolvePnPMethod method

    c'numPoints :: Int32
    c'numPoints = fromIntegral $ V.length objectImageMatches

    objectPoints :: V.Vector Point3d
    objectPoints = V.map (toPoint . fst) objectImageMatches

    imagePoints :: V.Vector Point2d
    imagePoints = V.map (toPoint . snd) objectImageMatches