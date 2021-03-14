#!/bin/bash

set -e

cleanup() {
  echo "Exit received"

  echo "Stopping server"
  ./lgsm-gameserver stop
  echo "Server Stopped"

  echo "Shutting down"
  exit 0
}

trap 'cleanup' SIGINT SIGTERM

update() {
  touch INSTALLING.LOCK

  ./lgsm-gameserver update || true
  exitcode="$?"

  if [ "$exitcode" -gt "0" ] && [ "$exitcode" != "3" ]; then
    # Retry once 
    echo "Unexpected error when updating ($exitcode). Trying again."
    ./lgsm-gameserver update || true
    exitcode="$?"
  fi

  rm -f INSTALLING.LOCK
  
  if [ "$exitcode" != "0" ] && [ "$exitcode" != "3" ]; then
    # exitcode 3 is a warning, in this case the warning we don't care about is steam not being installed
    # any other thing not being installed is an issue, but steam will be installed if it's missing.
    # we can't use the one in apt-get for some reason (it installs but it always hangs installing games) 
    echo "Unexpected exit code during install $exitcode"
    exit $exitcode
  fi

  echo "Game has been updated."
}

install() {
  touch INSTALLING.LOCK  
  ./linuxgsm.sh $LGSM_GAMESERVERNAME
  ln -s $LGSM_GAMESERVERNAME lgsm-gameserver || true
  ls -ltr
  ./lgsm-gameserver auto-install || true
  exitcode="$?"

  if [ "$exitcode" -gt "0" ] && [ "$exitcode" != "3" ]; then
    # Retry once 
    echo "Unexpected error when installing ($exitcode). Trying again."
    ./lgsm-gameserver auto-install || true
    exitcode="$?"
  fi

  echo "Install returned code $exitcode"
  rm -f INSTALLING.LOCK
    
  if [ "$exitcode" != "0" ] && [ "$exitcode" != "3" ]; then
    # exitcode 3 is a warning, in this case the warning we don't care about is steam not being installed
    # any other thing not being installed is an issue, but steam will be installed if it's missing.
    # we can't use the one in apt-get for some reason (it installs but it always hangs installing games) 
    echo "Unexpected exit code during uninstall $exitcode"
    exit $exitcode
  fi

  echo "Game has been installed."
}

# hack LGSM install_config.sh
fix_install_config() {
  # force override existing file when copy a file- allow to override already installed config files
  sed -i.bak 's/cp -nv/cp -v/g' "./lgsm/functions/install_config.sh"

  # disable download default config if file already exists
  # because config files are already present when we have cloned lgsm project 
  # and moved them at the right place before templating them
  # So we dont want to erase these files
  sed -i.bak 's/"forcedl"/""/g' "./lgsm/functions/install_config.sh"
}

# deploy config files
deploy_config() {
  echo "** Deploy config files"
  fix_install_config
  (
    set -a 
    # load lgsm configuration
    travistest=1 source ./lgsm-gameserver
    set +a
    # deploy default config files
    ./lgsm/functions/install_config.sh
  )
}


echo "** Lanching startup scripts if any"
for f in startup-scripts/*.sh; do
  if [ -f "$f" ]; then
    echo "- launch $f"
    bash "$f" -H || break
  fi
done

echo "** Check clientport and sourcetvport values"
if [ -n "$LGSM_PORT" ]; then
  
  if [ -z "$LGSM_CLIENTPORT" ]; then
    clientport=$(($LGSM_PORT-10))
    echo "Auto determine clientport"
    export LGSM_CLIENTPORT=$clientport
  fi
  echo "clientPort $LGSM_CLIENTPORT"
  if [ -z "$LGSM_SOURCETVPORT" ]; then
    sourcetvport=$(($LGSM_PORT+5))
    echo "Auto determine sourcetvport"
    export LGSM_SOURCETVPORT=$sourcetvport
  fi
  echo "sourcetvport $LGSM_SOURCETVPORT"
fi

echo "** Launching monitor API : /live /ready /gamedig"
./monitor &

echo "** Extract LGSM_ values from env"
parse-env --env "LGSM_" > env.json

# cleaning previous lock
rm -f INSTALLING.LOCK

echo "** Check steam game server name : $LGSM_GAMESERVERNAME"
if [ -z "$LGSM_GAMESERVERNAME" ]; then  echo "Need to set LGSM_GAMESERVERNAME environment with a value from https://github.com/GameServerManagers/LinuxGSM/tree/master/lgsm/config-default/config-lgsm"
  exit 1
fi

echo "** Check default config dir name : $LGSM_DEFAULT_CFG_DIRNAME"
if [ -z "$LGSM_DEFAULT_CFG_DIRNAME" ]; then  echo "Need to set LGSM_DEFAULT_CFG_DIRNAME environment with a value from https://github.com/GameServerManagers/Game-Server-Configs"
  exit 1
fi

echo "** IP is set to "${LGSM_IP}

echo "** Gomplating main config"
echo "    Templating lgsm/config-default/config-lgsm/common.cfg.tmpl into lgsm/config-lgsm/$LGSM_GAMESERVERNAME/common.cfg"
mkdir -p ~/linuxgsm/lgsm/config-lgsm/$LGSM_GAMESERVERNAME
gomplate -d env=~/linuxgsm/env.json -f ~/linuxgsm/lgsm/config-default/config-lgsm/common.cfg.tmpl -o ~/linuxgsm/lgsm/config-lgsm/$LGSM_GAMESERVERNAME/common.cfg
if [ -f ~/linuxgsm/lgsm/config-lgsm/$LGSM_GAMESERVERNAME/$LGSM_GAMESERVERNAME.cfg.tmpl ]; then
  gomplate -d env=~/linuxgsm/env.json -f ~/linuxgsm/lgsm/config-lgsm/$LGSM_GAMESERVERNAME/$LGSM_GAMESERVERNAME.cfg.tmpl -o ~/linuxgsm/lgsm/config-lgsm/$LGSM_GAMESERVERNAME/$LGSM_GAMESERVERNAME.cfg
fi

echo "** Gomplating all default game configs"
echo "    Templating lgsm/config-default/config-game-template/*/*.tmpl into lgsm/config-default/config-game/*/*"
for d in /home/linuxgsm/linuxgsm/lgsm/config-default/config-game-template/*/ ; do
    configGameFolder=$(basename $d)
    for f in $d/*.tmpl ; do
      configGameFile=$(basename $f)
      outputConfigGameFile=$(basename $f .tmpl)
      outputFile="/home/linuxgsm/linuxgsm/lgsm/config-default/config-game/$configGameFolder/$outputConfigGameFile"
      gomplate -f $f -o $outputFile
		  chmod u+x,g+x $outputFile
    done
done

echo "** Copy default config files in a place where LGSM can find them"
echo "    Copying lgsm/config-default/config-game/*/* into lgsm/config-default/config-game/*"
for f in /home/linuxgsm/linuxgsm/lgsm/config-default/config-game/$LGSM_DEFAULT_CFG_DIRNAME/*; do
    cp -v "${f}" /home/linuxgsm/linuxgsm/lgsm/config-default/config-game/
done



[ -z "$LGSM_GAMESERVERNAME" ] && LGSM_UPDATEINSTALLSKIP="SKIP"
echo "** Process install/update instruction : $LGSM_UPDATEINSTALLSKIP"


if [ -n "$LGSM_UPDATEINSTALLSKIP" ]; then
  case "$LGSM_UPDATEINSTALLSKIP" in
    "AUTO")
        if [ ! -f lgsm-gameserver ]; then
            install
        else
            update
        fi
        deploy_config
      ;;
    "UPDATE")
        if [ ! -f lgsm-gameserver ]; then
            echo "Please install it first"
            exit 1
        fi
        update
        deploy_config
        ;;
    "INSTALL")
        if [ ! -f lgsm-gameserver ]; then
          install
        else
          echo "Already installed"
        fi
        deploy_config
        ;;
    "SKIP")
        deploy_config
        ;;
  esac
fi

if [ ! -f lgsm-gameserver ]; then
    echo "No game is installed, please set LGSM_UPDATEINSTALLSKIP"
    exit 1
fi



echo "** Starting game"
./lgsm-gameserver start
sleep 30s
#

echo "** Game details"
./lgsm-gameserver details

if [ "$LGSM_CONSOLE_STDOUT" == "true" ]; then
  tail -F ~/linuxgsm/log/console/lgsm-gameserver-console.log 2>/dev/null &
fi

if [ "$LGSM_SCRIPT_STDOUT" == "true" ]; then
  tail -F ~/linuxgsm/log/script/lgsm-gameserver-script.log 2>/dev/null &
fi

if [ "$LGSM_ALERT_STDOUT" == "true" ]; then
  tail -F ~/linuxgsm/log/script/lgsm-gameserver-alert.log 2>/dev/null &
fi

if [ "$LGSM_GAME_STDOUT" == "true" ]; then
  tail -F ~/linuxgsm/log/server/output_log*.txt  2>/dev/null &
fi

wait $!
