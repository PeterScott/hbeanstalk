-----------------------------------------------------------------------------
-- |
-- Module      :  Beanstalk Tests
-- Copyright   :  (c) Greg Heartsfield 2010
-- License     :  BSD3
--
-- Test hbeanstalkh library against a real beanstalkd server.
-- This script assumes the server is running on localhost:11300, and can
-- be executed with `runhaskell Tests.hs`
-- For best results, this should probably be run against a newly started
-- server with zero jobs (restart server, and run without persistence)
-----------------------------------------------------------------------------

module Main(main) where

import Network.Beanstalk
import Control.Exception(finally)
import IO(bracket)
import Control.Concurrent.MVar
import Network.Socket
import Test.HUnit
import System.Random (randomIO)
import Data.Maybe(fromJust)
import qualified Data.Map as M

bs_host = "localhost"
bs_port = "11300"

-- | Run the tests
main = runTestTT tests

tests =
    TestList
    [
     TestLabel "Beanstalk Connect" beanstalkConnectTest,
     TestLabel "Use" useTest,
     TestLabel "Watch" watchTest,
     TestLabel "Put" putTest,
     TestLabel "Put2" putTest2,
     TestLabel "Put/Reserve" putReserveTest,
     TestLabel "Put/Reserve-With-Timeout" putReserveWithTimeoutTest,
     TestLabel "Peek" peekTest,
     TestLabel "KickDelay" kickDelayTest,
     TestLabel "Release" releaseTest,
     TestLabel "Ignore" ignoreTest
    ]

-- | Ensure that connection to a server works, or at least that no
--   exceptions are thrown.
beanstalkConnectTest =
    TestCase (
              do bs <- connectBeanstalk bs_host bs_port
                 mbSock <- tryTakeMVar bs
                 case mbSock of
                   Nothing -> do assertFailure "Beanstalk socket was not in the MVar as expected."
                   Just s ->
                             do sIsConnected s @? "Beanstalk socket was not connected"
                                (sIsBound s >>= return.not) @? "Beanstalk socket was bound"
                                (sIsListening s >>= return.not) @? "Beanstalk socket was not listening"
                                sIsReadable s @? "Beanstalk socket was not readable"
                                sIsWritable s @? "Beanstalk socket was not writable"
             )

-- Test that using a tube doesn't cause exceptions.
useTest =
    TestCase (
              do bs <- connectBeanstalk bs_host bs_port
                 randomName >>= useTube bs
                 return ()
             )

-- Test that watching a tube works.
watchTest =
    TestCase (
              do bs <- connectBeanstalk bs_host bs_port
                 tubeName <- randomName
                 watchCount <- watchTube bs tubeName
                 assertEqual "Watch list should consist of 'default' and newly watched tube"
                                 2 watchCount
             )

-- Test that ignoring a tube works
ignoreTest =
    TestCase (
              do bs <- connectBeanstalk bs_host bs_port
                 tubeName <- randomName
                 watchCount <- watchTube bs tubeName
                 assertEqual "Watch list should consist of 'default' and newly watched tube"
                                 2 watchCount
                 newWatchCount <- ignoreTube bs "default"
                 assertEqual "Watch list should consist of newly watched tube only"
                                 1 newWatchCount
             )

-- Simply test that connecting and putting a job in the default tube works without exceptions.
putTest =
    TestCase (
              do bs <- connectBeanstalk bs_host bs_port
                 (state, jobid) <- putJob bs 1 0 60 "body"
                 return ()
             )

-- More exhaustive test of Put in a new tube
putTest2 =
    TestCase (
              do (bs, tt) <- connectAndSelectRandomTube
                 assertReadyJobs bs tt 0 "Initially, no jobs"
                 (state, jobid) <- putJob bs 1 0 60 "body"
                 -- Technically could be BURIED, but only if memory exhausted.
                 assertEqual "New job is in state READY" READY state
                 assertReadyJobs bs tt 1 "Put creates a ready job in the tube"
                 return ()
             )
-- Test putting and then reserving a job
putReserveTest =
    TestCase (
              do (bs, tt) <- connectAndSelectRandomTube
                 randString <- randomName
                 let body = "My test job body, " ++ randString
                 (_,put_job_id) <- putJob bs 1 0 60 body
                 rsv_job <- reserveJob bs
                 assertEqual "Reserved job ID should match what was put" put_job_id (job_id rsv_job)
                 assertEqual "Reserved job body should match what was put" body (job_body rsv_job)
                 assertEqual "Reserved job should match job that was just put"
                             put_job_id (job_id rsv_job)
             )

-- Test putting and then reserving a job with timeout
putReserveWithTimeoutTest =
    TestCase (
              do (bs, tt) <- connectAndSelectRandomTube
                 randString <- randomName
                 let body = "My test job body, " ++ randString
                 (_,put_job_id) <- putJob bs 1 0 60 body
                 rsv_job <- reserveJobWithTimeout bs 2
                 assertEqual "Reserved job should match job that was just put"
                             put_job_id (job_id rsv_job)
             )

-- Test peeking for a couple specific jobs
peekTest =
    TestCase (
              do (bs, tt) <- connectAndSelectRandomTube
                 randString <- randomName
                 let body = "My test job body, " ++ randString
                 (_,put_job_id) <- putJob bs 1 0 60 body
                 let next_body = "My test job body, " ++ randString
                 (_,put_next_job_id) <- putJob bs 1 0 60 next_body
                 peeked_job <- peekJob bs put_job_id
                 assertEqual "Peeked job id should match job id that was just put"
                             put_job_id (job_id peeked_job)
                 assertEqual "Peeked job should match job that was just put"
                             body (job_body peeked_job)
                 next_peeked_job <- peekJob bs put_next_job_id
                 assertEqual "Peeked job id should match job id that was just put"
                             put_next_job_id (job_id next_peeked_job)
                 assertEqual "Peeked job should match job that was just put"
                             next_body (job_body next_peeked_job)
             )

kickDelayTest =
    TestCase (
              do (bs, tt) <- connectAndSelectRandomTube
                 randString <- randomName
                 let body = "My test job body, " ++ randString
                 (_,put_job_id) <- putJob bs 1 5 60 body
                 kicked <- kick bs 1
                 assertEqual "Kick should indicate one job kicked" 1 kicked
             )

releaseTest =
    TestCase (
              do (bs, tt) <- connectAndSelectRandomTube
                 assertReadyJobs bs tt 0 "New tube has no jobs"
                 -- Put a job on the tube
                 randString <- randomName
                 let body = "My test job body, " ++ randString
                 (_,put_job_id) <- putJob bs 1 0 60 body
                 assertReadyJobs bs tt 1 "Put adds job to tube"
                 -- Reserve the job
                 rj <- reserveJob bs
                 assertReadyJobs bs tt 0 "Reserve removes ready job"
                 -- Release it
                 releaseJob bs (job_id rj) 1 0
                 assertReadyJobs bs tt 1 "Release puts job back to ready"
              )

-- Assert a number of ready jobs on a given tube
assertReadyJobs :: BeanstalkServer -> String -> Int -> String -> IO ()
assertReadyJobs bs tube jobs msg =
    do ts <- statsTube bs tube
       let jobsReady = read (fromJust (M.lookup "current-jobs-ready" ts))
       assertEqual msg jobs jobsReady


-- Configure a new beanstalkd connection to use&watch a single tube
-- with a random name.
connectAndSelectRandomTube :: IO (BeanstalkServer, String)
connectAndSelectRandomTube =
    do bs <- connectBeanstalk bs_host bs_port
       tt <- randomName
       useTube bs tt
       watchTube bs tt
       ignoreTube bs "default"
       return (bs, tt)

-- Generate random tube names for test separation.
randomName :: IO String
randomName =
    do rdata <- randomIO :: IO Integer
       return (show (abs rdata))
