#!/bin/bash

DST_PATH="$HOME/.steam/steam/steamapps/common/Don't Starve Together Dedicated Server/bin64"
DST_BIN="dontstarve_dedicated_server_nullrenderer_x64"
DST_UPDATE=false
DST_STOP=false
DST_STATUS=false

CLUSTER_PATH="$HOME/.klei/DoNotStarveTogether"
CLUSTER_NAME=""

if ! command -v screen &> /dev/null; then
  echo "⚠️ 未找到 screen, 尝试安装中..."
  sudo apt install -y screen
  if [ $? -ne 0 ]; then
    echo "❌ screen 安装失败, 请自行安装: sudo apt install -y screen"
    exit 1
  fi
fi

for arg in "$@"; do
  case "$arg" in
    --update)
      DST_UPDATE=true
      ;;
    --stop|--kill)
      DST_STOP=true
      ;;
    --status)
      DST_STATUS=true
      ;;
    *)
      if [ -n "$arg" ] && [ -d "$CLUSTER_PATH/$arg" ]; then
        CLUSTER_NAME="$arg"
      fi
      ;;
  esac
done

function get_sessions() {
  if [ -z "$CLUSTER_NAME" ]; then
    mapfile -t sessions < <(screen -ls | awk '/DST_Master_|DST_Caves_/{print $1}')
  else
    sessions=()
    [ -d "$CLUSTER_PATH/$CLUSTER_NAME/Master" ] && sessions+=("DST_Master_$CLUSTER_NAME")
    [ -d "$CLUSTER_PATH/$CLUSTER_NAME/Caves" ] && sessions+=("DST_Caves_$CLUSTER_NAME")
  fi
}

function stop() {
  get_sessions

  if [ -z "$CLUSTER_NAME" ]; then
    if [ ${#sessions[@]} -eq 0 ]; then
      echo "⭕️ 未检测到任何 DST 会话"
      return 0
    fi
    read -p "未指定存档，是否停止所有 DST 服务？(y/N): " confirm
    [[ ! "$confirm" =~ ^[Yy][Ee]?[Ss]?$ ]] && { echo "取消操作"; return 0; }
  fi

  for session in "${sessions[@]}"; do
    if [ -n "$session" ] && screen -list | grep -q "$session"; then
      echo "⛔ 停止 $session ..."
      screen -S "$session" -X stuff $'\x03'
      sleep 3
      screen -S "$session" -X quit 2>/dev/null
    fi
  done
}

function show_status() {
  get_sessions
  
  if [ -z "$CLUSTER_NAME" ] && [ ${#sessions[@]} -eq 0 ]; then
    echo "⭕️ 未检测到任何 DST 会话"
    return 0
  fi

  for session in "${sessions[@]}"; do
    if [ -n "$session" ]; then
      if screen -list | grep -q "$session"; then
        echo "✅ $session 运行中"
      else
        echo "⛔ $session 未运行"
      fi
    fi
  done
}

if [ "$DST_STOP" = true ]; then
  stop
  exit 0
fi
if [ "$DST_STATUS" = true ]; then
  show_status
  exit 0
fi

function load_mods() {
  local mods_file="$CLUSTER_PATH/$CLUSTER_NAME/Master/modoverrides.lua"
  if [ ! -f "$mods_file" ]; then
    if [ -f "$CLUSTER_PATH/$CLUSTER_NAME/Caves/modoverrides.lua" ]; then
      mods_file="$CLUSTER_PATH/$CLUSTER_NAME/Caves/modoverrides.lua"
    else
      echo "⚠️ 未找到 modoverrides.lua, 跳过 mod 加载"
      return 0
    fi
  fi

  local mod_ids=$(tr -d '\r' < "$mods_file" | sed 's/‐/-/g' | grep -oE 'workshop-[0-9]+' | sort -u)
  [ -z "$mod_ids" ] && { echo "⚠️ 未找到任何 mod, 跳过 mod 加载"; return 0; }

  echo "🔄 读取 mod ..."

  local setup_file="$DST_PATH/../mods/dedicated_server_mods_setup.lua"
  mkdir -p "$(dirname "$setup_file")"
  : > "$setup_file"

  while IFS= read -r mod_id; do
    echo "ServerModSetup(\"$mod_id\")" >> "$setup_file"
    local mod_num=$(echo "$mod_id" | grep -oE '[0-9]+' || true)
    if [ -n "$mod_num" ]; then
      echo "ServerModSetup(\"$mod_num\")" >> "$setup_file"
    fi
  done <<< "$mod_ids"

  local mod_count=$(printf "%s\n" "$mod_ids" | sed '/^$/d' | wc -l)
  echo "✅ 共读取到 $mod_count 个 mod"
}

function start() {
  if [ ! -d "$CLUSTER_PATH/$CLUSTER_NAME" ]; then
    echo "❌ 存档不存在: $CLUSTER_NAME"
    exit 1
  fi

  stop
  load_mods
  sleep 1

  cd "$DST_PATH"

  if [ -d "$CLUSTER_PATH/$CLUSTER_NAME/Master" ]; then
    echo "🚀 地面 服务启动中..."
    screen -dmS "DST_Master_$CLUSTER_NAME" ./$DST_BIN -cluster "$CLUSTER_NAME" -shard Master
    sleep 3
    if screen -list | grep -q "DST_Master_$CLUSTER_NAME"; then
      echo "✅ 地面 服务已启动"
    else
      echo "❌ 地面 服务启动失败"
      exit 1
    fi
  fi

  if [ -d "$CLUSTER_PATH/$CLUSTER_NAME/Caves" ]; then
    echo "🚀 洞穴 服务启动中..."
    screen -dmS "DST_Caves_$CLUSTER_NAME" ./$DST_BIN -cluster "$CLUSTER_NAME" -shard Caves
    sleep 2
    if screen -list | grep -q "DST_Caves_$CLUSTER_NAME"; then
      echo "✅ 洞穴 服务已启动"
    else
      echo "⚠️ 洞穴 服务启动失败（无洞穴可忽略）"
    fi
  fi

  echo "🗒️ 运行日志, 出现 Sim paused 则说明启动成功 ( Ctrl + C 隐藏 )"
  if [ -d "$CLUSTER_PATH/$CLUSTER_NAME/Master" ] && [ ! -d "$CLUSTER_PATH/$CLUSTER_NAME/Caves" ]; then
    tail -f "$CLUSTER_PATH/$CLUSTER_NAME/Master/server_log.txt"
  else
    tail -f "$CLUSTER_PATH/$CLUSTER_NAME/Caves/server_log.txt"
  fi
}

function select_cluster() {
  cd "$CLUSTER_PATH" 2>/dev/null || { echo "❌ 无法访问存档目录"; exit 1; }

  local i=1
  local clusters=()

  echo -e "\n请选择存档:\n"
  for dir in */; do
    if [ -d "$dir" ]; then
      cluster_name=$(basename "$dir")
      clusters[$i]="$cluster_name"
      echo "[ $i ] $cluster_name"
      i=$((i+1))
    fi
  done

  if [ ${#clusters[@]} -eq 0 ]; then
    echo "⭕️ 没有找到任何存档, 请先上传存档到 $CLUSTER_PATH 目录"
    exit 1
  fi

  echo ""
  read -p "请选择存档序号( Ctrl+C 取消 ): " choice

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$i" ]; then
    CLUSTER_NAME="${clusters[$choice]}"
    echo "✅ 选择存档: $CLUSTER_NAME"
  else
    echo "❌ 无效的存档序号"
    exit 1
  fi

  start
}

function update() {
  echo "🔄 检查 DST 更新 ..."

  local STEAMCMD=$(command -v steamcmd || echo "$HOME/steamcmd" || echo "/usr/games/steamcmd")
  "$STEAMCMD" +login anonymous +app_update 343050 validate +quit

  if [ $? -eq 0 ]; then
    echo -e "✅ DST 更新成功\n"
  else
    echo "❌ DST 更新失败"
    exit 1
  fi
}

function check() {
  local STEAMCMD=$(command -v steamcmd || echo "$HOME/steamcmd" || echo "/usr/games/steamcmd")

  if ! [ -x "$STEAMCMD" ]; then
    echo "⚠️ 未找到 steamcmd, 尝试安装中..."

    sudo add-apt-repository multiverse
    sudo dpkg --add-architecture i386
    sudo apt update
    apt-cache show lib32gcc-s1 2>/dev/null | grep -q . && \
      sudo apt-get install -y lib32gcc-s1 || \
      sudo apt-get install -y lib32gcc1
    sudo apt-get install -y steamcmd

    if [ $? -ne 0 ] || [ ! -f "/usr/games/steamcmd" ]; then
      echo -e "❌ 安装失败, 请自行安装 [ https://developer.valvesoftware.com/wiki/Zh/SteamCMD ]"
      exit 1
    fi

    sudo ln -sf /usr/games/steamcmd /usr/local/bin/steamcmd
    ln -sf /usr/games/steamcmd "$HOME/steamcmd" 2>/dev/null || true
    echo "✅ steamcmd 安装成功"
  fi

  if [ ! -d "$DST_PATH" ] || [ "$DST_UPDATE" = true ]; then
    update
  fi

  if [ ! -x "$DST_PATH/$DST_BIN" ]; then
    echo "❌ DST 不存在或不可执行: $DST_PATH/$DST_BIN"
    exit 1
  fi

  mkdir -p "$CLUSTER_PATH"
}

function help() {
  echo -e "\n使用说明: $0 [options] [cluster]\n"
  echo -e "    options: 指令, 例: $0 --status"
  echo -e "        --update         更新 DST"
  echo -e "        --stop, --kill   停止 DST"
  echo -e "        --status         显示运行状态\n"
  echo -e "    cluster: 使用存档, 例: $0 Cluster_1\n"
}

check

if [ -z "$CLUSTER_NAME" ]; then
  select_cluster
elif [ -d "$CLUSTER_PATH/$CLUSTER_NAME" ]; then
  echo "✅ 使用存档: $CLUSTER_NAME"
  start
else
  help
fi
