#!/bin/bash

#############
## HISTORY ##
#############
# 22 Feb 2021 - forked from cyber-jack (who added discord support) wangee
#             - comments translated from german to english for a better understanding
#             - Added curl verbosity (verbosecurl boolean)
#             - Added -c argument to curl to handle cookies updates


###############################################################################################
# Standard configuration can be changed with a specific configuration
getStdConf () {
  # directories
  dataDir="./data"
  tmpDir="./tmp"
  logDir="./log"

  # config files
  inFileCid="cid.txt"
  inFileAsset="asset.txt"
  inFileCookie="cookies.txt"

  # working files
  outFileNew="$dataDir/newPos.csv"
  outFileOld="$dataDir/oldPos.csv"
  outFilePosOpen="$dataDir/openPos.csv"
  outFilePosClose="$dataDir/closePos.csv"
  outFileCTrades="$dataDir/ctrades.csv"
  outFileChangeTP="$dataDir/changedTP.csv"
  outFileChangeSL="$dataDir/changedSL.csv"
  outFileMsg="$dataDir/msgFile.txt"
  outFileLock="$tmpDir/lock.tmp"

  # parameters
  maxHOpen=1
  nrNotFoundClosedPos=0
  verbosecurl="false"

}


###############################################################################################
# a single query at eToro
curlCrawl () {
  # Variable initialization & configuration
  local url="$1"
  local lCount=0
  local lMax=10
  local tDelay=20
  local fetchWorked=0

  while [ $fetchWorked -eq 0 -a $lCount -le $lMax ]; do

    # get a unique number for the request
    local rNumber=`uuid`

    # assemble the url for the request
    local urlTot="$url&client_request_id=$rNumber"

    # fetch the data from eToro
    if [ "$verbosecurl" == "true" ]; then
            retValCurlCrawl=`curl -v -b $inFileCookie -c $inFileCookie -s "$urlTot"`
    else
            retValCurlCrawl=`curl -b $inFileCookie -c $inFileCookie -s "$urlTot"`
    fi

    # check output
    if [[ "$retValCurlCrawl" != *"failureReason"* ]]; then
      fetchWorked=1
    else
      # sleep and try again
      echo "Seems blocked from eToro"
      sleep $((lCount*tDelay))
      ((lCount++))
    fi
  done

  # abort on error
  if [ $fetchWorked -ne 1 ]; then
    echo "Error: New cookie file required"
    if [ "$silentMode" == "false" ]; then
        if [ "$discord" == "true" ]; then
                ./discord.sh --webhook-url $webhook --username $username --avatar $avatar --text "Maintenance message: New cookie required. Pausing bot."
        else
                ./telegram -t $tgAPI -c $tgcID "Maintenance message: New cookie required. Pausing bot."
        fi
    else
       echo "Maintenance message: New cookie required. Pausing bot."
    fi
    cp "$outFileOld" "$outFileNew"
    exit 1
  fi

  # Check on error message of eToro
  if [[ "$retValCurlCrawl" == *"<title>50"* ]]; then
      echo $retValCurlCrawl
      echo "##########################"
      echo $urlTot
      echo "Error: eToro seems not available"

    ## clean up for the next start (copy the old output back)
    revertAndTerminate
  fi
}


###############################################################################################
# Control bot termination
revertAndTerminate() {
   if [ "$silentMode" == "false" ]; then
        if [ "$discord" == "true" ]; then
                ./discord.sh --webhook-url $webhook --username $username --avatar $avatar --text "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
        else
                ./telegram -t $tgAPI -c $tgcID "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
        fi
  else
     echo "Maintenance message: eToro seems not available. Bot will be started in a few minutes again"
  fi
  cp "$outFileOld" "$outFileNew"
  rmFile $outFileLock
  exit 1
}


###############################################################################################
# Get cid from eToro or from a local file

getCidfFileOrUpdate () {
  # check if cid is already known
  cid=`grep "$trader" "$inFileCid"`
  if [ "$?" -ne "0" ]; then
     echo "Info: fetching cid from etoro directly"
     # fetch trader information
     urlTot="https://www.etoro.com/api/logininfo/v1.1/users/$trader"
    if [ "$verbosecurl" == "true" ]; then
     traderInfo=`curl -v -b $inFileCookie -c $inFileCookie -s "$urlTot"`
    else
     traderInfo=`curl -b $inFileCookie -c $inFileCookie -s "$urlTot"`
    fi

     # extract cid
     cid=`echo $traderInfo | awk -F "," '{print $2}' | awk -F ":" '{print $2}'`

     # check cid (should be a number with multiple digits)
     if [[ $cid == +([0-9]) ]]; then
        echo \"$trader\",$cid >> $inFileCid
     else
       echo "Error: Configuration error, trader not found"
   #    ./telegram -t $tgAPI -c $tgcID "Error message: Configuration error. Pausing bot."
       exit 1
     fi
  else
    cid=${cid##*,}
  fi
}


###############################################################################################
# Get data from eToro

fetchEToroData() {
  # Variable initialization & configuration
  outFile="$1"
  basePUrl="https://www.etoro.com/sapi/trade-data-real/live/public/portfolios?format=json&cid="
  baseAUrl="https://www.etoro.com/sapi/trade-data-real/live/public/positions?format=json&InstrumentID="

  # fetch cid from config list or from eToro
  getCidfFileOrUpdate

  # Compose the URL
  url="$basePUrl$cid"

  # Tap data
  retValCurlCrawl=""
  curlCrawl "$url"

  # Check data
  if [[ "$retValCurlCrawl" != *"CreditByRealizedEquity"* ]]; then
     echo "Fetch of portfolio did not work. Pausing bot"
     revertAndTerminate
  fi

  # Make sure the file is empty
  rmFile "$outFile"

  # make sure positions are available
  emptyPortfolio=0
  if [[ "$retValCurlCrawl" == *"\"AggregatedPositions\":[]"* ]]; then
    echo "Empty portfolio"
    emptyPortfolio=1
  fi

  # make sure there is no error
  if [[ "$retValCurlCrawl" == *"ErrorCode"* ]]; then
    echo "Empty portfolio with error code"
    # lockfile removal
    rmFile $outFileLock
    exit 0
  fi

  if [[ "$emptyPortfolio" == "0" ]]; then

    # only filter out the AggregatedPositions
    fContent=$retValCurlCrawl
    fContent=${fContent%%\}],\"AggregatedMirrors*}
    fContent=${fContent##*AggregatedPositions\":[{}

    # go through each asset class and get all corresponding trades
    for assetClass in $(echo $fContent | sed 's/},{/\n/g'); do
      # Extract asset number
      assetClass=${assetClass%%,\"Direction*}
      assetClass=${assetClass##\"InstrumentID\":}

      # Compose the URL
      url=$baseAUrl$assetClass"&cid="$cid

      # Tap data
      curlCrawl "$url"

      # Check data
      if [[ "$retValCurlCrawl" != *"PublicPositions"* ]]; then
         echo $retValCurlCrawl
         echo "Fetch of position did not work. Pausing bot"
         revertAndTerminate
      fi

      # Extract data
      fContent=$retValCurlCrawl
      fContent=${fContent%%\}]\}}
      fContent=${fContent##*PublicPositions\":[{}

      for asset in $(echo $fContent | sed 's/},{/\n/g'); do
        echo $asset >> $outFile
      done

    done
  fi

  # assure that each line is a resonable line. To this end I check for a key word
  touch $outFile
  cp $outFile "$outFile"_tmp
  grep "CurrentRate" "$outFile"_tmp > $outFile
  rmFile "$outFile"_tmp
}

###############################################################################################
# Check new positions

checkNewOpen () {
  dSLong=`echo $1 | awk -F "," '{print $3}'`
  dStringPos=${dSLong:16:28}

  dValPos=`date --date="$dStringPos" +%s`
  dValNow=`date +%s`

  dValDiff=$((dValNow-dValPos))
  dValMax=$(($maxHOpen*60*60))

  if [ $dValDiff -gt $dValMax ]; then
    echo "Position to long open and therefore ignored"
    return 1
  fi
  return 0
}


###############################################################################################
# Recognize changed positions

# Identify newly opened, closed and changed positions
identDifference () {
  inFileNew="$outFileNew"
  inFileOld="$outFileOld"

  # Create temporary files
  tmpFilePosNew=`tempfile -d $tmpDir`
  tmpFilePosOld=`tempfile -d $tmpDir`
  tmpFilePosDiff=`tempfile -d $tmpDir`

  # positionsnummer extct position numbers
  sort "$inFileNew" | awk -F "," '{print $1}' > "$tmpFilePosNew"
  sort "$inFileOld" | awk -F "," '{print $1}' > "$tmpFilePosOld"
  diff "$tmpFilePosOld" "$tmpFilePosNew" > "$tmpFilePosDiff"

  # find new positions
  rmFile "$outFilePosOpen"
  for newPos in $(grep ">" $tmpFilePosDiff | awk '{print $2}'); do
     #grep "$newPos" "$inFileNew" >> "$outFilePosOpen"
    newPosStr=`grep "$newPos" "$inFileNew"`
    checkNewOpen $newPosStr
    rVal=$?
    if [ "$rVal" -eq "0" ]; then
       echo $newPosStr >> "$outFilePosOpen"
    fi
  done

  # find closed positions
  rmFile "$outFilePosClose"
  for oldPos in $(grep "<" $tmpFilePosDiff | awk '{print $2}'); do
    grep "$oldPos" "$inFileOld" >> "$outFilePosClose"
  done

  # find changed positions
  rmFile "$outFileChangeTP"
  rmFile "$outFileChangeSL"
  for posID in $(cat $tmpFilePosNew); do
    posNew=`grep "$posID" "$inFileNew"`
    posOld=`grep "$posID" "$inFileOld"`
    if [ $? -eq 0 ]; then
      # Changed Take Profit
      tpNew=`echo "$posNew" | awk -F "," '{print $7}'`
      tpOld=`echo "$posOld" | awk -F "," '{print $7}'`
      if [ "$tpNew" != "$tpOld" ]; then echo "$posNew" > "$outFileChangeTP"; fi

      # Stop Loss changed
      slNew=`echo "$posNew" | awk -F "," '{print $8}'`
      slOld=`echo "$posOld" | awk -F "," '{print $8}'`
      if [ "$slNew" != "$slOld" ]; then echo "$posNew" > "$outFileChangeSL"; fi
    fi
  done

  # cleanup
  rmFile "$tmpFilePosNew"
  rmFile "$tmpFilePosOld"
  rmFile "$tmpFilePosDiff"
}

###############################################################################################
# Get the closed trades of the last 2 to 3 days
getCTrades() {
  # get the date of today and yesterday
  dDBYesterday=`date -d "2 day ago" '+%Y-%m-%d'`

  # get uuid for the request
  rNumber=`uuid`

  # get json with the number of closed trades
  urlTot="https://www.etoro.com/sapi/trade-data-real/history/public/credit/flat/aggregated?CID=$cid&StartTime="$dDBYesterday"T00:00:00.000Z&format=json&client_request_id="$rNumber
  if [ "$verbosecurl" == "true" ]; then
     retValCurl=`curl -v -b $inFileCookie -c $inFileCookie -s "$urlTot"`
  else
     retValCurl=`curl -b $inFileCookie -c $inFileCookie -s "$urlTot"`
  fi

  # check output
  if [[ "$retValCurl" != *"TotalClosedTrades"* ]]; then
   revertAndTerminate
  fi

  # filter out the number of closed trade
  nrCTrades=${retValCurl%%\,\"TotalClosedManualPositions\"*}
  nrCTrades=${nrCTrades##\{\"TotalClosedTrades\":}

  # reset closed trades file
  rmFile $outFileCTrades
  touch $outFileCTrades

  # get the closed trades
  pageNr=1
  nrCTradesLeft=$nrCTrades
  while [ $nrCTradesLeft -ge 0 ]; do
    # get uuid for the request
    rNumber=`uuid`
    urlTot="https://www.etoro.com/sapi/trade-data-real/history/public/credit/flat?CID="$cid"&ItemsPerPage=100&PageNumber="$pageNr"&StartTime="$dDBYesterday"T00:00:00.000Z&format=json&client_request_id="$rNumber
    if [ "$verbosecurl" == "true" ]; then
       retValCurl=`curl -v -b $inFileCookie -c $inFileCookie -s "$urlTot"`
    else
       retValCurl=`curl -b $inFileCookie -c $inFileCookie -s "$urlTot"`
    fi

    # update counters
    nrCTradesLeft=$((nrCTradesLeft-30))
    pageNr=$(($pageNr+1))

    # Check data
    if [[ "$retValCurl" != *"PublicHistoryPositions"* ]]; then
      revertAndTerminate
    fi

    # Extract data
    fContent=$retValCurl
    fContent=${fContent%%\}]\}}
    fContent=${fContent##*PublicHistoryPositions\":[{}

    for asset in $(echo $fContent | sed 's/},{/\n/g'); do
      echo $asset >> $outFileCTrades
    done
  done
}

###############################################################################################
# Checks whether trades are really closed

checkPCloseTrades() {
  if [ -f "$outFilePosClose" ]; then

    # get the real closed positions
    getCTrades

    # transfer possibly closed trades to temp file
    mv $outFilePosClose $outFilePosClose"_tmp"

    # check each possibly closed position
    while read line; do
       # get the Position number
       posNr=${line##\"PositionID\":}
       posNr=${posNr%%,\"CID*}

       # search position in the real closed trades
       posClosed=`grep "$posNr" "$outFileCTrades"`
       if [ "$?" -eq "0" ]; then
          # position found therefore really finished trade
          echo $line >> $outFilePosClose
       else
          # position not found, therefore still open trade
          echo "Position not closed..."
          echo $line >> $outFileNew
          nrNotFoundClosedPos=$((nrNotFoundClosedPos+1))
       fi
    done <$outFilePosClose"_tmp"

    # clean up
    rmFile $outFilePosClose"_tmp"
  fi
}



###############################################################################################
# Generate messages
# Convert position from etoro to message
lineToMessage () {
  local msgTyp="$1"
  local pos="$2"
  local index="$3"

  local assetnr=`echo $pos | awk -F "," '{print $5}'`
  local time=`echo $pos | awk -F "," '{print $3}'`
  local time=${time#*\:}
  local open=`echo $pos | awk -F "," '{print $4}'`
  local bsType=`echo $pos | awk -F "," '{print $6}'`
  if [[ $bsType == *"true"* ]]; then
     bs="long";
     bsp=1;
  else
     bs="short";
     bsp=-1;
  fi
  local tp=`echo $pos | awk -F "," '{print $7}'`
  local cr=`echo $pos | awk -F "," '{print $12}'`
  local sl=`echo $pos | awk -F "," '{print $8}'`
  local levarage=`echo $pos | awk -F "," '{print $16}'`
  local np=`echo $pos | awk -F "," '{print $14}'`
  local np2=${np##*\:}
  local amount=`echo $pos | awk -F "," '{print $11}'`
  amount=${amount##*\:}

  # Convert asset number to asset name
  local asset=`grep -m1 "${assetnr##*\:}" "$inFileAsset"`
  if [ "$?" -ne "0" ]; then
    echo "Error Asset not found"
    exit 1
  fi
  asset=${asset##*,}

  open=${open##*\:}
  tp=${tp##*\:}
  cr=${cr##*\:}
  sl=${sl##*\:}
  levarage=${levarage##*\:}

  local tpp=`echo "scale=10;$bsp*100*($tp-$open)/$open*$levarage" | bc`
  local slp=`echo "scale=10;$bsp*100*($sl-$open)/$open*$levarage" | bc`

  cat >>$outFileMsg"_"$(printf "%03d" $index) << EOF
********************
<b>$msgTyp</b> $bs position
  Time: ${time:1:16}
  Asset:        $asset
  open: $open
  TP:   $tp   (${tpp:0:7} %)
  CR:   $cr   (${np2:0:7} %)
  SL:   $sl   (${slp:0:7} %)
  Levarage:     ${levarage##*\:}
  Amount:   ${amount:0:4} %
EOF
#  NP:  ${np2:0:10}

}

# Create messages from file with positions
msgFromFile () {
local fName="$1"
local mType="$2"

if [ -f "$fName" ]; then
  # Create a header if the file is not already there
  if [ ! -f $outFileMsg"_000" ]; then
    datum=`date`
    cat>>$outFileMsg"_000" << EOL
####################
Position changed
  Trader: $trader
  Date:   $datum
####################
EOL
  fi

  local index=`ls "$outFileMsg"* 2>/dev/null | wc -l`
  for pos in $(cat $fName); do
    lineToMessage "$mType" "$pos" "$index"
    ((index++))
  done
fi
}


# make sure file is empty
rmFile () {
  local fName="$1"
  touch $fName
  rm $fName
}


# Prepare messages for telegram
msgCreate () {

# make sure file is empty
rmFile $outFileMsg

# send new positions
msgFromFile "$outFilePosOpen" "New"

# Send closed positions
msgFromFile "$outFilePosClose" "Closed"

# TP change
msgFromFile "$outFileChangeTP" "Changed TP"

# SL change
msgFromFile "$outFileChangeSL" "Changed SL"
}

# Send message
msgSend () {
  if [ -f $outFileMsg"_000" ]; then
    local msgFiles=$outFileMsg"_*"
    for msg in $msgFiles; do

      if [ "$silentMode" == "false" ]; then
        if [ "$iscord" == "true" ]; then
                cat $msg
                ./discord.sh --webhook-url $webhook --username $username --avatar $avatar --title "New Notification!" --description "$(jq -Rs . <$msg | tr -d "*" | awk '{gsub("<b>", "**");gsub("</b>", "**");print}'| cut -c 2- | rev | cut -c 2- | rev)"
        else
                cat $msg | ./telegram -H -t $tgAPI -c $tgcID -
        fi
      else
         cat $msg
      fi

      rmFile $msg
    done
    if [ "$silentMode" == "false" ]; then
        if [ "$discord" == "true" ]; then
                ./discord.sh --webhook-url $webhook --username $username --avatar $avatar --text "Maintenance message: New cookie required. Pausing bot."
        else
                ./telegram -t $tgAPI -c $tgcID "Portfolio:https://www.etoro.com/people/$trader/portfolio"$'\n'
        fi
      if [ "$nrNotFoundClosedPos" -ne "0" ]; then
        if [ "$discord" == "true" ]; then
                ./discord.sh --webhook-url $webhook --username $username --avatar $avatar --text "Maintenance message: New cookie required. Pausing bot."
        else
                ./telegram -t $tgAPI -c $tgcID "Maintenance message: Possibly closed position found."
        fi
      fi
    fi
  fi
}

# Make sure this script is run only once and don't run after an error
lockFileGen () {

# check that a lockfile does not already exist
  if [ -f  $outFileLock ]; then
    # Abort
    echo "Info: Lockfile exists. Therefore aborted bot"
    exit 1
  fi

  # Create lockfile with the current execution time
  date > $outFileLock

}

###############################################################################################
# Make sure you have all the files you need
initFiles () {
  touch $outFileNew
  touch $outFileOld
}


###############################################################################################
# Main program

# change to the working directory
cd "$(dirname "$0")"

# Default settings
silentMode=false

while [ -n "$1" ]; do # while loop starts
    case "$1" in
    -s) echo "Using silent mode"
        silentMode=true ;; # Silent mode
#    -b) echo "-b option passed" ;; # Message for -b option
#    -c) echo "-c option passed" ;; # Message for -c option
    *) echo "Option $1 not recognized" ;; # In case you typed a different option other than a,b,c
    esac
    shift
done

# load standard configuration
getStdConf

# load specific configuration
source eToroSBot.conf

# Initialize the files
initFiles

# Make sure you run only once and don't run after an error
lockFileGen

# save old data
cp "$outFileNew" "$outFileOld"

# Get data from eToro
fetchEToroData "$outFileNew"

# Looking for a change in positions
identDifference

# Check closed trades
checkPCloseTrades

# Create messages
msgCreate

# send message with telegram
msgSend

# Copy all positions into the log directory
cp "$outFileNew" "$logDir/`date "+%g%m%d__%H_%M"`"

# Remove lockfile
rmFile $outFileLock
