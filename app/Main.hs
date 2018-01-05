{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude hiding (last)

import Control.Concurrent (threadDelay)
import Control.Monad (forever, when)
import System.Cron
import System.Cron.Parser

import Data.Maybe as M
import Data.Text as Text hiding (words, unword, map)
import qualified Data.Bson as Bson
import Network.HaskellNet.SMTP.SSL as SMTP

import Date
import User
import Interest
import Mail
import News
import Location
import Weather
import Html
import Database as DB
import Error as E
import Config

createNewGeoLoc :: String -> IO Location.GeoLoc
createNewGeoLoc address = do
  geoLocAttempt <- Location.getGeoLocFromString address
  if M.isNothing geoLocAttempt
    then E.callError "Error. Main. createNewGeoLoc: failed when requesting location coordinates from address"
    else return $ M.fromJust geoLocAttempt

createNewUser :: IO User
createNewUser = do
  putStrLn "\n.::. NEW USER .::.\n"
  putStrLn "> First Name:"
  userFirstName <- getLine
  putStrLn "> Last Name:"
  userLastName <- getLine
  let userName = User.newName userFirstName userLastName
  putStrLn "> E-mail Address:"
  userEmail <- getLine
  let userEmail' = Mail.stringToAddress userEmail
  putStrLn "> User's location (e.g: 'rosario, santa fe, argentina'):"
  userLocationAddress <- getLine
  userGeoLoc <- createNewGeoLoc userLocationAddress
  putStrLn "> Interests (keywords separated by a space):"
  userInterestsString <- getLine
  let userInterests = Interest.toDataType $ words userInterestsString
  newUser <- User.newUser userName userEmail' userGeoLoc userInterests
  if M.isNothing newUser
    then do
      putStrLn "Error: Email address not valid. User not uploaded to DB. Create new user again, please.\n"
      createNewUser
    else return $ M.fromJust newUser

sendWelcomeMailToUser :: User -> IO ()
sendWelcomeMailToUser user = do
  let userEmailAddress = User.getEmail user
  conn <- Mail.connect
  Mail.auth conn
  Mail.send conn userEmailAddress "Welcome to dailyHASK" "plain text body" (Html.renderWelcomeMailTemplate user)
  Mail.closeConnection conn
  return ()

collection :: IO Text
collection = do
  value <- Config.getValue "database.usersCollection"
  let value' = M.fromJust value
  return $ Text.pack value'

doWork :: IO ()
doWork = let
  workActions :: SMTPConnection -> Bson.Document -> IO ()
  workActions conn user = do
    let _id = M.fromJust $ Bson.lookup "_id" user :: User.ID

    let name = M.fromJust $ Bson.lookup "name" user :: Bson.Document
    let firstName = M.fromJust $ Bson.lookup "first" name :: Text
    let lastName = M.fromJust $ Bson.lookup "last" name :: Text
    let name' = Name firstName lastName :: User.Name

    let email = M.fromJust $ Bson.lookup "email" user :: Text

    let location = M.fromJust $ Bson.lookup "location" user :: Bson.Document
    let address = M.fromJust $ Bson.lookup "address" location :: Text
    let lat = M.fromJust $ Bson.lookup "lat" location :: Double
    let long = M.fromJust $ Bson.lookup "long" location :: Double
    let location' = GeoLoc address lat long :: GeoLoc

    let interests = Bson.typed $ Bson.valueAt "interests" user :: [Interest]

    let userRecord = User _id name' email location' interests :: User

    news <- News.getNews interests
    putStrLn "News articles retrieved from API..."
    currentWeather <- Weather.getCurrentWeatherFromGeoLoc $ User.getLocation userRecord
    putStrLn "Weather information retrieved from API..."
    if M.isNothing news || M.isNothing currentWeather
      then E.callError "Error. Main: couldn't retrive news articles. Aborting..."
      else let
        news' = M.fromJust news
        currentWeather' = M.fromJust currentWeather
        in do
          Mail.send conn email "Your dailyHASK" "plain text body" (Html.renderDailyMailTemplate userRecord news' currentWeather')
          putStrLn "Daily mail sent to user/s..."

  work :: [Bson.Document] -> SMTPConnection -> IO ()
  work users conn = do
    mapM_ (workActions conn) users
  in do
    putStrLn "Processing database..."
    collection <- collection
    pipe <- DB.open
    users <- DB.findAll pipe [] collection
    DB.close pipe
    conn <- Mail.connect
    Mail.auth conn
    work users conn
    Mail.closeConnection conn
    putStrLn "Process finished."

main :: IO ()
main = do
  putStrLn ">> Select hour parameter to construct a cronjob"
  h <- getLine
  putStrLn ">> Select minute parameter to construct a cronjob"
  m <- getLine
  main' h m

main' :: String -> String -> IO ()
main' h m = do
  newUser <- createNewUser
  sendWelcomeMailToUser newUser
  putStrLn "> Want to create another user? [Y/N]"
  line <- getLine
  if line == "Y" || line == "y"
    then main' h m
    else forever $ do
      now <- Date.getCurrentTimeFromServer
      when (scheduleMatches schedule now) doWork
      threadDelay 60000000 -- delay 1 minute to skip schedule
    where
      cronSpec = Text.pack (m ++ " " ++ h ++ " * * *")
      schedule = either (E.callError "Error at configuring cron schedule (it should not happen). Aborting...") id (parseCronSchedule cronSpec)
