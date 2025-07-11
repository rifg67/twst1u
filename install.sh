#!/bin/bash

# =====================
#  NIKU TUNNEL INSTALLER
# =====================
# ✅ MERCURY VPN - All In One VPN Installer
# =========================================

# ----- WARNA ----- #
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
IPVPS=$(curl -s ipv4.icanhazip.com)
ALLOWED_FILE="/opt/niku-bot/allowed.json"

# ----- CEK IZIN ----- #
echo -e "${YELLOW}[ INFO ] Mengecek izin akses VPS...${NC}"
if [ ! -f "$ALLOWED_FILE" ]; then
  echo -e "${RED}[ ERROR ] File allowed.json tidak ditemukan di $ALLOWED_FILE${NC}"
  exit 1
fi
IS_ALLOWED=$(jq -r '.authorized_ips[]?.ip' "$ALLOWED_FILE" | grep -w "$IPVPS")
if [[ -z "$IS_ALLOWED" ]]; then
  echo -e "${RED}[ DITOLAK ] IP VPS $IPVPS tidak terdaftar di sistem bot.${NC}"
  exit 1
fi

# ----- DEPENDENSI ----- #
echo -e "${YELLOW}[ INFO ] Menginstall dependensi dasar...${NC}"
apt update -y &>/dev/null
apt install -y jq curl socat git net-tools cron unzip screen iptables-persistent python3 python3-websocket openssl stunnel4 dropbear squid badvpn netcat neofetch &>/dev/null

# ----- SET TIMEZONE ----- #
ln -fs /usr/share/zoneinfo/Asia/Jakarta /etc/localtime
dpkg-reconfigure -f noninteractive tzdata &>/dev/null

# ----- INSTALL XRAY ----- #
echo -e "${YELLOW}[ INFO ] Menginstall Xray Core...${NC}"
mkdir -p /etc/xray
cd /etc/xray || exit
curl -sLO https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip
unzip -o Xray-linux-64.zip &>/dev/null
install -m 755 xray /usr/local/bin/xray
rm -f Xray-linux-64.zip xray geo* LICENSE README.md

# ----- SSL CERTIFICATE (ACME) ----- #
echo -e "${YELLOW}[ INFO ] Menginstall SSL ACME...${NC}"
curl https://get.acme.sh | sh &>/dev/null
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

# ----- DOMAIN SETUP ----- #
echo -e "${YELLOW}[ INFO ] Setup domain dan SSL...${NC}"
read -rp "Masukkan domain yang sudah dipointing ke VPS ini: " DOMAIN
mkdir -p /etc/xray
~/.acme.sh/acme.sh --issue --standalone -d $DOMAIN --keylength ec-256 --force
~/.acme.sh/acme.sh --install-cert -d $DOMAIN --ecc \
--key-file /etc/xray/key.pem \
--fullchain-file /etc/xray/cert.pem

# ----- KONFIGURASI XRAY (VMESS/VLESS/TROJAN) ----- #
echo -e "${YELLOW}[ INFO ] Setup konfigurasi Xray WS TLS/Non-TLS...${NC}"
UUID=$(cat /proc/sys/kernel/random/uuid)
cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$UUID","flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "/etc/xray/cert.pem",
            "keyFile": "/etc/xray/key.pem"
          }]
        },
        "wsSettings": {"path": "/vless"}
      }
    },
    {
      "port": 80,
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "$UUID"}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {"path": "/vmess"}
      }
    },
    {
      "port": 2087,
      "protocol": "trojan",
      "settings": {
        "clients": [{"password": "$UUID"}]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "/etc/xray/cert.pem",
            "keyFile": "/etc/xray/key.pem"
          }]
        },
        "wsSettings": {"path": "/trojan"}
      }
    }
  ],
  "outbounds": [{"protocol": "freedom"}]
}
EOF

# ----- SYSTEMD SERVICE XRAY ----- #
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service by MERCURY VPN
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# ----- SSH WS NON-TLS ----- #
echo -e "${YELLOW}[ INFO ] Setup SSH WebSocket Non-TLS...${NC}"
cat > /etc/systemd/system/ws-nontls.service <<EOF
[Unit]
Description=SSH WebSocket NonTLS
After=network.target

[Service]
ExecStart=/usr/bin/python3 -u -m websocket_server 0.0.0.0 80 /bin/login
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# ----- STUNNEL TLS ----- #
echo -e "${YELLOW}[ INFO ] Setup SSH TLS via Stunnel...${NC}"
cat > /etc/stunnel/stunnel.conf <<EOF
cert = /etc/xray/cert.pem
key = /etc/xray/key.pem
[dropbear]
accept = 443
connect = 127.0.0.1:109
EOF
sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

systemctl daemon-reload
systemctl enable stunnel4 ws-nontls
systemctl restart stunnel4 ws-nontls

# ----- DROPBEAR & BADVPN ----- #
echo -e "${YELLOW}[ INFO ] Setup Dropbear dan BadVPN...${NC}"
echo "/bin/false" >> /etc/shells
sed -i 's/NO_START=1/NO_START=0/g' /etc/default/dropbear
sed -i 's/DROPBEAR_PORT=22/DROPBEAR_PORT=109/g' /etc/default/dropbear
sed -i 's/DROPBEAR_EXTRA_ARGS=""/DROPBEAR_EXTRA_ARGS="-p 143"/g' /etc/default/dropbear
systemctl enable dropbear
systemctl restart dropbear

screen -dmS badvpn badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000 --max-connections-for-client 10

# ----- AUTOSTART & BANNER ----- #
echo -e "${YELLOW}[ INFO ] Setup Autologin Banner...${NC}"
cat > /etc/issue.net <<EOF
==============================
   MERCURY VPN - NIKU TUNNEL
==============================
IP : $IPVPS
Domain : $DOMAIN
==============================
EOF

echo 'Banner /etc/issue.net' >> /etc/ssh/sshd_config
systemctl restart sshd

# Menu CLI
log_info "Pasang menu CLI..."
mkdir -p /root/menu && cd /root/menu
wget -q https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/menu.sh
wget -q https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/menu-ssh.sh
wget -q https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/menu-vmess.sh
wget -q https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/menu-vless.sh
wget -q https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/menu-trojan.sh
wget -q https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/menu-tools.sh
chmod +x *.sh

mkdir -p /root/menu/ssh
wget -q -O /root/menu/ssh/create.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/create.sh
wget -q -O /root/menu/ssh/autokill.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/autokill.sh
wget -q -O /root/menu/ssh/cek.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/cek.sh
wget -q -O /root/menu/ssh/lock.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/lock.sh
wget -q -O /root/menu/ssh/list.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/list.sh
wget -q -O /root/menu/ssh/delete-exp.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/delete-exp.sh
wget -q -O /root/menu/ssh/delete.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/delete.sh
wget -q -O /root/menu/ssh/unlock.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/unlock.sh
wget -q -O /root/menu/ssh/trial.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/trial.sh
wget -q -O /root/menu/ssh/multilogin.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/multilogin.sh
wget -q -O /root/menu/ssh/renew.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/ssh/renew.sh

mkdir -p /root/menu/vmess
wget -q -O /root/menu/vmess/create.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/create.sh
wget -q -O /root/menu/vmess/autokill.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/renew.sh
wget -q -O /root/menu/vmess/cek.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/cek.sh
wget -q -O /root/menu/vmess/lock.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/trial.sh
wget -q -O /root/menu/vmess/list.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/list.sh
wget -q -O /root/menu/vmess/delete-exp.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/delete-exp.sh
wget -q -O /root/menu/vmess/delete.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vmess/delete.sh

mkdir -p /root/menu/vless
wget -q -O /root/menu/vless/create.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/create.sh
wget -q -O /root/menu/vless/autokill.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/renew.sh
wget -q -O /root/menu/vless/cek.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/cek.sh
wget -q -O /root/menu/vless/lock.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/trial.sh
wget -q -O /root/menu/vless/list.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/list.sh
wget -q -O /root/menu/vless/delete-exp.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/delete-exp.sh
wget -q -O /root/menu/vless/delete.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/vless/delete.sh

mkdir -p /root/menu/trojan
wget -q -O /root/menu/trojan/create.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/create.sh
wget -q -O /root/menu/trojan/autokill.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/renew.sh
wget -q -O /root/menu/trojan/cek.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/cek.sh
wget -q -O /root/menu/trojan/lock.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/trial.sh
wget -q -O /root/menu/trojan/list.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/list.sh
wget -q -O /root/menu/trojan/delete-exp.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/delete-exp.sh
wget -q -O /root/menu/trojan/delete.sh https://raw.githubusercontent.com/NIKU1323/nikucloud-autoinstall/main/menu/trojan/delete.sh

chmod +x /root/menu/*.sh
chmod +x /root/menu/menu-tools/*.sh
chmod +x /root/menu/ssh/*.sh
chmod +x /root/menu/vless/*.sh
chmod +x /root/menu/trojan/*.sh
chmod +x /root/menu/vmess/*.sh
[[ $(grep -c menu.sh /root/.bashrc) == 0 ]] && echo "clear && bash /root/menu/menu.sh" >> /root/.bashrc

# Biar bisa akses cukup ketik "menu"
ln -sf /root/menu/menu.sh /usr/local/bin/menu
chmod +x /usr/local/bin/menu

log_success "✅ INSTALLASI BERHASIL! Jalankan ulang VPS dan tes koneksi di aplikasi."
read -p "Reboot sekarang? (y/n): " jawab
[[ "$jawab" == "y" || "$jawab" == "Y" ]] && reboot
