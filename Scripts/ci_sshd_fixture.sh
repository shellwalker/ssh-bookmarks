#!/usr/bin/env bash
# 在本机起两个临时 sshd，供集成测试使用。只监听 127.0.0.1。
# start 把连接参数写到 build/sshd-fixture.env（不含密码明文）。
# stop 结束 sshd。测试用户留在一次性 runner 上，不写回仓库。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${MENUSH_SSHD_DIR:-/tmp/menush-ci-sshd}"
ENV_FILE="$ROOT/build/sshd-fixture.env"
USER_NAME="menushssh"
ASKPASS="$DIR/askpass"

usage() {
  echo "usage: $0 start|stop" >&2
  exit 2
}

stop_one() {
  local pidfile="$1"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" || true)"
    if [[ -n "${pid}" ]]; then
      sudo kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
}

stop() {
  stop_one "$DIR/sshd-a.pid"
  stop_one "$DIR/sshd-b.pid"
}

enable_login() {
  local password="$1"
  # sysadminctl 新建的账号经常带“已过期”策略，sshd 会在公钥通过后仍被 PAM 拒绝。
  sudo pwpolicy -u "$USER_NAME" -clearaccountpolicies >/dev/null 2>&1 || true
  sudo dscl . -delete "/Users/$USER_NAME" accountPolicyData >/dev/null 2>&1 || true
  sudo /usr/sbin/sysadminctl -resetPasswordFor "$USER_NAME" -newPassword "$password" >/dev/null 2>&1 || true
  if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
    sudo dseditgroup -o edit -a "$USER_NAME" -t user com.apple.access_ssh >/dev/null 2>&1 || true
  fi
}

ensure_user() {
  local password="$1"
  if id "$USER_NAME" >/dev/null 2>&1; then
    sudo /usr/sbin/sysadminctl -resetPasswordFor "$USER_NAME" -newPassword "$password" >/dev/null 2>&1 \
      || sudo dscl . -passwd "/Users/$USER_NAME" "$password" >/dev/null 2>&1
    return
  fi
  if ! sudo /usr/sbin/sysadminctl -addUser "$USER_NAME" \
    -fullName "MenuSSH CI" \
    -password "$password" \
    -home "/Users/$USER_NAME" \
    -shell /bin/zsh >/dev/null 2>&1
  then
    local uid=550
    while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -qx "$uid"; do
      uid=$((uid + 1))
    done
    sudo dscl . -create "/Users/$USER_NAME"
    sudo dscl . -create "/Users/$USER_NAME" UserShell /bin/zsh
    sudo dscl . -create "/Users/$USER_NAME" RealName "MenuSSH CI"
    sudo dscl . -create "/Users/$USER_NAME" UniqueID "$uid"
    sudo dscl . -create "/Users/$USER_NAME" PrimaryGroupID 20
    sudo dscl . -create "/Users/$USER_NAME" NFSHomeDirectory "/Users/$USER_NAME"
    sudo mkdir -p "/Users/$USER_NAME"
    sudo chown "$USER_NAME:staff" "/Users/$USER_NAME"
    sudo dscl . -passwd "/Users/$USER_NAME" "$password" >/dev/null 2>&1
  fi
}

write_config() {
  local port="$1"
  local pidfile="$2"
  local path="$3"
  cat >"$path" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $DIR/ssh_host_ed25519_key
PidFile $pidfile
AuthorizedKeysFile /Users/$USER_NAME/.ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
UsePAM yes
AllowTcpForwarding yes
AllowAgentForwarding yes
PermitRootLogin no
StrictModes no
UseDNS no
MaxStartups 50:30:200
PerSourcePenalties no
LogLevel VERBOSE
PrintMotd no
PrintLastLog no
Subsystem sftp internal-sftp
AllowUsers $USER_NAME
MaxAuthTries 4
ClientAliveInterval 20
EOF
}

wait_port() {
  local port="$1"
  local i
  for i in $(seq 1 50); do
    if nc -z 127.0.0.1 "$port"; then
      return 0
    fi
    sleep 0.1
  done
  echo "sshd did not listen on $port" >&2
  sudo cat "$DIR/sshd-a.log" >&2 || true
  sudo cat "$DIR/sshd-b.log" >&2 || true
  return 1
}

start() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "sshd fixture requires macOS" >&2
    exit 1
  fi
  mkdir -p "$DIR" "$ROOT/build" "$DIR/.ssh"
  chmod 755 "$DIR"
  # Password stays in the askpass script (mode 700), not in the env file or logs.
  local password
  password="menush-ci-$(openssl rand -hex 8)"
  ensure_user "$password"
  enable_login "$password"
  cat >"$ASKPASS" <<EOF
#!/bin/sh
printf '%s\n' '$password'
EOF
  chmod 700 "$ASKPASS"
  unset password

  ssh-keygen -q -t ed25519 -f "$DIR/ssh_host_ed25519_key" -N ""
  ssh-keygen -q -t ed25519 -f "$DIR/id_ed25519" -N ""
  chmod 600 "$DIR/id_ed25519" "$DIR/ssh_host_ed25519_key"
  # sshd 以降权后的用户读 authorized_keys。放在该用户自己的 ~/.ssh，避免 /tmp 目录权限导致 Permission denied。
  sudo mkdir -p "/Users/$USER_NAME/.ssh"
  sudo cp "$DIR/id_ed25519.pub" "/Users/$USER_NAME/.ssh/authorized_keys"
  sudo chown -R "$USER_NAME:staff" "/Users/$USER_NAME/.ssh"
  sudo chmod 700 "/Users/$USER_NAME/.ssh"
  sudo chmod 600 "/Users/$USER_NAME/.ssh/authorized_keys"
  cat >"$DIR/.ssh/config" <<'EOF'
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
EOF
  chmod 644 "$DIR/.ssh/config"
  # -J 的跳板连接不一定继承命令行 -o。把主机密钥检查关掉写进系统配置的最前面（第一次出现的值生效）。
  if ! sudo grep -q 'MENUSH-CI-HOSTKEY' /etc/ssh/ssh_config 2>/dev/null; then
    local prefix
    prefix="$(mktemp)"
    cat >"$prefix" <<'EOF'
# MENUSH-CI-HOSTKEY
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    sudo sh -c "cat '$prefix' /etc/ssh/ssh_config > /etc/ssh/ssh_config.menush && mv /etc/ssh/ssh_config.menush /etc/ssh/ssh_config"
    rm -f "$prefix"
  fi

  local port_a port_b
  port_a=22221
  port_b=22222
  write_config "$port_a" "$DIR/sshd-a.pid" "$DIR/sshd-a.conf"
  write_config "$port_b" "$DIR/sshd-b.pid" "$DIR/sshd-b.conf"
  sudo /usr/sbin/sshd -f "$DIR/sshd-a.conf" -E "$DIR/sshd-a.log"
  sudo /usr/sbin/sshd -f "$DIR/sshd-b.conf" -E "$DIR/sshd-b.log"
  wait_port "$port_a"
  wait_port "$port_b"
  sudo chmod a+r "$DIR"/sshd-*.log "$DIR"/sshd-*.pid 2>/dev/null || true

  cat >"$ENV_FILE" <<EOF
MENUSH_INTEGRATION=1
MENUSH_SSH_USER=$USER_NAME
MENUSH_SSH_KEY=$DIR/id_ed25519
MENUSH_SSH_PORT_A=$port_a
MENUSH_SSH_PORT_B=$port_b
MENUSH_SSH_ASKPASS=$ASKPASS
MENUSH_SSH_HOME=$DIR
EOF
  chmod 600 "$ENV_FILE"
  echo "sshd fixture ready on 127.0.0.1:$port_a and :$port_b"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) usage ;;
esac
