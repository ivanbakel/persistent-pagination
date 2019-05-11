{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE DeriveFoldable      #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveTraversable   #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | This module provides efficient pagination over your database queries.
-- No @OFFSET@ here - we use ranges to do this right!
--
-- The ideal "range" column for a datatype has a few properties:
--
-- 1. It should have an index. An index on the column will dramatically
--   improve performance on pagination.
-- 2. It should be monotonic - that is, we shouldn't be able to insert new
--   data into the middle of a range. An example would be a @created_at@
--   timestamp field, or a auto-incrementing primary key.
--
-- This module offers two ways to page through a database. You can use the
-- 'streamingEntities' to get a 'ConduitT' of @'Entity' record@ values
-- streaming out. Or, if you'd like finer control, you can use 'getPage'
-- to get the first page of data, and then 'nextPage' to get the next
-- possible page of data.
module Database.Persist.Pagination where

import           Conduit
import           Control.Applicative
import           Control.Applicative    (Const (..))
import qualified Control.Foldl          as Foldl
import           Control.Monad.Reader
import           Data.Foldable
import           Data.List              (foldl')
import           Data.Maybe
import           Data.Monoid hiding ((<>))
import           Data.Semigroup
import           Database.Persist.Class
import           Database.Persist.Sql
import           Lens.Micro

-- | Stream entities out of the database, only pulling a limited amount
-- into memory at a time.
--
-- You should use this instead of 'selectSource' because 'selectSource'
-- doesn't really work. It doesn't work at all in MySQL, and it's somewhat
-- sketchy with PostgreSQL and SQLite. This function is guaranteed to use
-- only as much memory as a single page, and if  you tune the page size
-- right, you'll get efficient queries from the database.
--
-- There's an open issue for 'selectSource' not working:
-- <https://github.com/yesodweb/persistent/issues/657 GitHub Issue>.
--
-- @since 0.1.0.0
streamEntities
    :: forall record backend typ m a.
    ( PersistRecordBackend record backend
    , PersistQueryRead backend
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => [Filter record]
    -- ^ The filters to apply.
    -> EntityField record typ
    -- ^ The field to sort on. This field should have an index on it, and
    -- ideally, the field should be monotonic - that is, you can only
    -- insert values at either extreme end of the range. A @created_at@
    -- timestamp or autoincremented ID work great for this. Non-monotonic
    -- keys can work too, but you may miss records that are inserted during
    -- a traversal.
    -> PageSize
    -- ^ How many records in a page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range. Provide @'Range' Nothing Nothing@ if you want
    -- everything in the database.
    -> ConduitT a (Entity record) (ReaderT backend m) ()
streamEntities filters field pageSize sortOrder range = do
    mpage <- lift (getPage filters field pageSize sortOrder range)
    forM_ mpage loop
  where
    loop page = do
        yieldMany (pageRecords page)
        mpage <- lift (nextPage page)
        forM_ mpage loop

-- | The amount of records in a 'Page' of results.
--
-- @since 0.1.0.0
newtype PageSize = PageSize { unPageSize :: Int }
    deriving (Eq, Show)

-- | Whether to sort by @ASC@ or @DESC@ when you're paging over results.
--
-- @since 0.1.0.0
data SortOrder = Ascend | Descend
    deriving (Eq, Show)

-- | A datatype describing the min and max value of the relevant field that
-- you are ranging over in a non-empty sequence of records.
--
-- @since 0.1.0.0
data Range t = Range { rangeMin :: t, rangeMax :: t }
    deriving (Eq, Show, Functor, Foldable, Traversable)

instance Ord t => Semigroup (Range t) where
    Range l h <> Range l' h' = Range (min l l') (max h h')

instance (Bounded t, Ord t) => Monoid (Range t) where
    mempty = Range minBound maxBound
    mappend = (<>)

-- | Users aren't required to put a value in for the range - a value of
-- 'Nothing' is equivalent to saying "unbounded from below."
--
-- @since 0.1.0.0
type DesiredRange t = Range (Maybe t)

-- | A @'Page' record typ@ describes a list of records and enough
-- information necessary to acquire the next page of records, if possible.
--
-- @since 0.1.0.0
data Page record typ
    = Page
    { pageRecords      :: [Entity record]
    -- ^ The collection of records.
    --
    -- @since 0.1.0.0
    , pageRecordCount  :: Int
    -- ^ The count of records in the collection. If this number is less
    -- than the 'pageSize' field, then a call to 'nextPage' will result in
    -- 'Nothing'.
    --
    -- @since 0.1.0.0
    , pageRange        :: Range typ
    -- ^ The minimum and maximum value of @typ@ in the list.
    --
    -- @since 0.1.0.0
    , pageDesiredRange :: DesiredRange typ
    -- ^ The desired range in the next page of values. When the
    -- 'pageSortOrder' is 'Ascending', then the 'rangeMin' value will
    -- increase with each page until the set of data is complete. Likewise,
    -- when the 'pageSortOrder' is 'Descending', then the 'rangeMax' will
    -- decrease until the final page is reached.
    --
    -- @since 0.1.0.0
    , pageField        :: EntityField record typ
    -- ^ The field to sort on. This field should have an index on it, and
    -- ideally, the field should be monotonic - that is, you can only
    -- insert values at either extreme end of the range. A @created_at@
    -- timestamp or autogenerated ID work great for this. Non-monotonic
    -- keys can work too, but you may miss records that are inserted during
    -- a traversal.
    --
    -- @since 0.1.0.0
    , pageFilters      :: [Filter record]
    -- ^ The extra filters that are placed on the query.
    --
    -- @since 0.1.0.0
    , pageSize         :: PageSize
    -- ^ The desired size of the 'Page' for successive results.
    , pageSortOrder    :: SortOrder
    -- ^ Whether to sort on the 'pageField' in 'Ascending' or 'Descending'
    -- order. The choice you make here determines how the
    -- 'pageDesiredRange' changes with each page.
    --
    -- @since 0.1.0.0
    }

-- | Convert a @'DesiredRange' typ@ into a list of 'Filter's for the query.
-- The 'DesiredRange' is treated as an exclusive range.
--
-- @since 0.1.0.0
rangeToFilters
    :: PersistField typ
    => Range (Maybe typ)
    -> EntityField record typ
    -> [Filter record]
rangeToFilters range field =
    fmap (field >.) (toList (rangeMin range))
    ++
    fmap (field <.) (toList (rangeMax range))

-- | Get the first 'Page' according to the given criteria. This returns
-- a @'Maybe' 'Page'@, because there may not actually be any records that
-- correspond to the query you issue. You can call 'pageRecords' on the
-- result object to get the row of records for this page, and you can call
-- 'nextPage' with the 'Page' object to get the next page, if one exists.
--
-- This function gives you lower level control over pagination than the
-- 'streamEntities' function.
--
-- @since 0.1.0.0
getPage
    :: forall record backend typ m.
    ( PersistRecordBackend record backend
    , PersistQueryRead backend
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => [Filter record]
    -- ^ The filters to apply.
    -> EntityField record typ
    -- ^ The field to sort on. This field should have an index on it, and
    -- ideally, the field should be monotonic - that is, you can only
    -- insert values at either extreme end of the range. A @created_at@
    -- timestamp or autogenerated ID work great for this. Non-monotonic
    -- keys can work too, but you may miss records that are inserted during
    -- a traversal.
    -> PageSize
    -- ^ How many records in a page
    -> SortOrder
    -- ^ Ascending or descending
    -> DesiredRange typ
    -- ^ The desired range. Provide @'Range' Nothing Nothing@ if you want
    -- everything in the database.
    -> ReaderT backend m (Maybe (Page record typ))
getPage filts field pageSize sortOrder desiredRange = do
    erecs <- selectList filters selectOpts
    case erecs of
        [] ->
            pure Nothing
        rec:recs ->
            pure (Just (mkPage rec recs))
  where
    selectOpts =
        LimitTo (unPageSize pageSize) : case sortOrder of
            Ascend  -> [Asc field]
            Descend -> [Desc field]
    filters =
        filts <> rangeToFilters desiredRange field
    mkPage rec recs = flip Foldl.fold (rec:recs) $ do
        let recs' = rec : recs
            rangeDefault = initRange rec
        maxRange <- Foldl.premap (Just . Max . (^. fieldLens field)) Foldl.mconcat
        minRange <- Foldl.premap (Just . Min . (^. fieldLens field)) Foldl.mconcat
        len <- Foldl.length
        pure Page
            { pageRecords = rec : recs
            , pageRange = fromMaybe rangeDefault $
                Range <$> fmap getMin minRange <*> fmap getMax maxRange
            , pageDesiredRange = desiredRange
            , pageField = field
            , pageFilters = filts
            , pageSize = pageSize
            , pageRecordCount = len
            , pageSortOrder = sortOrder
            }
    initRange :: Entity record -> Range typ
    initRange rec =
        Range
            { rangeMin = rec ^. fieldLens field
            , rangeMax = rec ^. fieldLens field
            }

-- | Retrieve the next 'Page' of data, if possible.
--
-- @since 0.1.0.0
nextPage
    ::
    ( PersistRecordBackend record backend
    , PersistQueryRead backend
    , Ord typ
    , PersistField typ
    , MonadIO m
    )
    => Page record typ -> ReaderT backend m (Maybe (Page record typ))
nextPage Page{..}
    | pageRecordCount < unPageSize pageSize =
        pure Nothing
    | otherwise =
        getPage
            pageFilters
            pageField
            pageSize
            pageSortOrder
            (bumpPageRange pageSortOrder pageDesiredRange pageRange)

-- | Modify the 'DesiredRange' according to the 'Range' that was provided
-- by the query and the 'SortOrder'.
--
-- @since 0.1.0.0
bumpPageRange
    :: Ord typ
    => SortOrder
    -> DesiredRange typ
    -> Range typ
    -> DesiredRange typ
bumpPageRange sortOrder (Range mmin mmax) (Range min' max') =
    case sortOrder of
        Ascend ->
            Range (mmin `max` Just max') mmax
        Descend ->
            Range mmin (Just min' <|> (Just min' `min` mmax))
