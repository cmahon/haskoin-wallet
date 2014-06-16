{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Node.HeaderChain where

import Control.Monad
import Control.Applicative
import Control.Monad.Trans
import Control.Monad.Trans.Either
import qualified Control.Monad.State as S

import Data.Bits
import Data.Word
import Data.Maybe
import Data.Binary
import Data.Binary.Get
import Data.Binary.Put
import Data.Default
import qualified Data.ByteString as BS

import qualified Database.LevelDB.Base as DB

import Network.Haskoin.Node.Checkpoints
import Network.Haskoin.Crypto
import Network.Haskoin.Protocol
import Network.Haskoin.Util

-- | Lower bound for the proof of work difficulty
proofOfWorkLimit :: Integer
proofOfWorkLimit = fromIntegral (maxBound `shiftR` 32 :: Hash256)

-- | Time between difficulty cycles (2 weeks on average)
targetTimespan :: Word32
targetTimespan = 14 * 24 * 60 * 60

-- | Time between blocks (10 minutes per block)
targetSpacing :: Word32
targetSpacing = 10 * 60

-- | Number of blocks on average between difficulty cycles (2016 blocks)
diffInterval :: Word32
diffInterval = targetTimespan `div` targetSpacing

data Session = Session { handle :: DB.DB }

type DBHandle = S.StateT Session IO

-- Represent a node in the block header chain
data BlockHeaderNode 
    = BlockHeaderGenesis
        { nodeBlockId      :: !Hash256
        , nodeHeader       :: !BlockHeader
        , nodeHeaderHeight :: !Word32
        , nodeChainWork    :: !Integer
        }
    | BlockHeaderNode 
        { nodeBlockId      :: !Hash256
        , nodeHeader       :: !BlockHeader
        , nodeHeaderHeight :: !Word32
        , nodeChainWork    :: !Integer
        , nodeParent       :: !Hash256
        } deriving (Show, Read, Eq)

instance Binary BlockHeaderNode where

    get = go =<< get
      where
        genid = blockid genesis
        go i | i == genid = BlockHeaderGenesis i <$> get 
                                                 <*> getWord32le 
                                                 <*> get 
             | otherwise  = BlockHeaderNode i <$> get 
                                              <*> getWord32le 
                                              <*> get 
                                              <*> get

    put (BlockHeaderGenesis i b h w) =
        put i >> put b >> putWord32le h >> put w
    put (BlockHeaderNode i b h w p) =
        put i >> put b >> putWord32le h >> put w >> put p


-- Return value of linking a new block header in the chain
-- TODO: Add more options if required
data BlockHeaderAction
    = RejectHeader String
    | HeaderAlreadyExists BlockHeaderNode
    | AcceptHeader BlockHeaderNode
    deriving (Show, Read, Eq)

indexKey :: Hash256 -> BS.ByteString
indexKey h = "index_" `BS.append` encode' h

headKey :: BS.ByteString
headKey = "chainhead"

-- Insert the genesis block if it is not already there
initDB :: DBHandle ()
initDB = S.gets handle >>= \db -> do
    prevGen <- DB.get db def $ indexKey genid
    when (isNothing prevGen) $ DB.write db def
        [ DB.Put (indexKey genid) $ encode' BlockHeaderGenesis
           { nodeBlockId      = genid
           , nodeHeader       = genesis
           , nodeHeaderHeight = 0
           , nodeChainWork    = headerWork genesis
           }
        , DB.Put headKey $ encode' genid
        ]
  where
    genid = blockid genesis

-- bitcoind function ProcessBlockHeader and AcceptBlockHeader in main.cpp
-- TODO: Add DOS return values
addBlockHeader :: BlockHeader -> Word32 -> DBHandle BlockHeaderAction
addBlockHeader bh adjustedTime = ((f <$>) . runEitherT) $ do
    db <- lift $ S.gets handle
    unless (checkProofOfWork bh) $ 
        left $ RejectHeader "Invalid proof of work"
    unless (blockTimestamp bh <= adjustedTime + 2 * 60 * 60) $
        left $ RejectHeader "Invalid header timestamp"
    existsM <- lift $ DB.get db def $ indexKey bid
    unless (isNothing existsM) $
        left $ HeaderAlreadyExists $ decode' $ fromJust existsM
    prevNodeM <- lift $ DB.get db def $ indexKey $ prevBlock bh
    let prevNode  = decode' $ fromJust prevNodeM
    unless (isJust prevNodeM) $
        left $ RejectHeader "Previous block not found"
    nextWork <- lift $ getNextWorkRequired prevNode
    unless (blockBits bh == nextWork) $
        left $ RejectHeader "Incorrect work transition (bits)"
    -- TODO: Implement nodeMedianTimePast
    -- unless (blockTimestamp bh > nodeMedianTimePast prevNode) $
    --     left $ RejectHeader "Block timestamp is too early"
    chkPointM <- lift lastCheckpoint
    let chkPoint  = fromJust chkPointM
        newHeight = nodeHeaderHeight prevNode + 1
    unless (isNothing chkPointM || (fromIntegral newHeight) > fst chkPoint) $
        left $ RejectHeader "Rewriting pre-checkpoint chain"
    unless (verifyCheckpoint (fromIntegral newHeight) bid) $
        left $ RejectHeader "Rejected by checkpoint lock-in"
    -- TODO: Implement isSuperMajority
    -- unless (version bh >= 2 || (not $ isSuperMajority 2 prevNode)) $
    --     left $ RejectHeader "Rejected version=1 block"
    lift $ storeBlockHeader bh prevNode
  where
    f (Right x) = x
    f (Left  x) = x
    bid = blockid bh

storeBlockHeader :: BlockHeader -> BlockHeaderNode 
                 -> DBHandle BlockHeaderAction
storeBlockHeader bh prevNode = S.gets handle >>= \db -> do
    DB.put db def (indexKey bid) $ encode' newNode
    -- TODO: Can fromJust ever fail ?
    currentHeadId <- fromJust <$> (DB.get db def headKey)
    currentHead   <- (decode' . fromJust) <$> 
                        (DB.get db def $ indexKey $ decode' currentHeadId)
    -- TODO: We're not handling reorgs here. What is the reorg logic in
    -- headers-first mode? Do we only reorg on blocks?
    when (nodeChainWork newNode > nodeChainWork currentHead) $ 
        DB.put db def headKey $ encode' bid
    return $ AcceptHeader newNode
  where
    bid       = blockid bh
    newHeight = nodeHeaderHeight prevNode + 1
    newWork   = nodeChainWork prevNode + headerWork bh
    newNode   = BlockHeaderNode { nodeBlockId      = bid
                                , nodeHeader       = bh
                                , nodeHeaderHeight = newHeight
                                , nodeChainWork    = newWork
                                , nodeParent       = prevBlock bh
                                }

-- bitcoind function GetNextWorkRequired in main.cpp
-- TODO: Add testnet support
getNextWorkRequired :: BlockHeaderNode -> DBHandle Word32
getNextWorkRequired (BlockHeaderGenesis _ _ _ _) = 
    return $ encodeCompact proofOfWorkLimit
getNextWorkRequired lastNode
    -- Only change the difficulty once per interval
    | (nodeHeaderHeight lastNode + 1) `mod` diffInterval /= 0 = 
        return $ blockBits $ nodeHeader lastNode
    | otherwise = do
        -- TODO: Can this break if there are not enough block in the chain?
        firstNode <- foldM (\x f -> f x) lastNode fs
        let t  = fromIntegral $ (blockTimestamp $ nodeHeader lastNode) - 
                                (blockTimestamp $ nodeHeader firstNode)
            timespan 
                | t < targetTimespan `div` 4 = targetTimespan `div` 4
                | t > targetTimespan * 4     = targetTimespan * 4
                | otherwise                  = t
            lastDiff = decodeCompact $ blockBits $ nodeHeader lastNode
            newDiff  = lastDiff * (toInteger timespan) `div` 
                       (toInteger targetTimespan)
        return $ encodeCompact $ if newDiff > proofOfWorkLimit
            then proofOfWorkLimit
            else newDiff
  where
    fs = replicate (fromIntegral diffInterval - 1) getParent

-- This can fail if the node has no parent 
getParent :: BlockHeaderNode -> DBHandle BlockHeaderNode
getParent (BlockHeaderGenesis _ _ _ _) = error "Genesis block has no parent"
getParent node = S.gets handle >>= \db -> do
    bsM <- DB.get db def $ indexKey $ nodeParent node
    -- TODO: We assume decode' will succeed as we are managing this database
    return $ decode' $ fromJust bsM

bestHeight :: DBHandle Word32
bestHeight = S.gets handle >>= \db -> do
    h <- fromJust <$> DB.get db def headKey
    b <- fromJust <$> (DB.get db def $ indexKey $ decode' h)
    return $ nodeHeaderHeight $ decode' b

-- Only return the best hash
-- TODO: Change this in the context of headers-first?
blockLocator :: DBHandle [Hash256]
blockLocator = S.gets handle >>= \db -> do
    h <- fromJust <$> DB.get db def headKey
    return [decode' h]

-- Get the last checkpoint that we have seen
lastCheckpoint :: DBHandle (Maybe (Int, Hash256))
lastCheckpoint = S.gets handle >>= \db -> 
    foldM (f db) Nothing $ reverse checkpointsList
  where
    f db res (i,chk) = if isJust res then return res else do
        haveChk <- DB.get db def $ indexKey chk
        return $ if isJust haveChk then Just (i,chk) else Nothing

-- Pure function

-- bitcoind function CheckProofOfWork in main.cpp
-- TODO: Return an error message?
checkProofOfWork :: BlockHeader -> Bool
checkProofOfWork bh
    | target <= 0 || target > proofOfWorkLimit = False
    | otherwise = getProofOfWork bh <= fromIntegral target
  where
    target = decodeCompact $ blockBits bh

getProofOfWork :: BlockHeader -> Integer
getProofOfWork =  bsToInteger . BS.reverse . encode' . blockid

-- | Returns the work represented by this block. Work is defined as the number 
-- of tries needed to solve a block in the average case with respect to the
-- target.
headerWork :: BlockHeader -> Integer
headerWork bh = 
    largestHash `div` (target + 1)
  where
    target      = decodeCompact (blockBits bh)
    largestHash = 1 `shiftL` 256

genesis :: BlockHeader
genesis = BlockHeader 
            (fromIntegral $ genesisHeader !! 0)
            (fromIntegral $ genesisHeader !! 1)
            (fromIntegral $ genesisHeader !! 2)
            (fromIntegral $ genesisHeader !! 3)
            (fromIntegral $ genesisHeader !! 4)
            (fromIntegral $ genesisHeader !! 5)
