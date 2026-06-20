sudo tee /tmp/test-mount.sh > /dev/null << 'EOF'
#!/bin/bash
set -x

SERVER_IP="169.254.190.157"
SHARE_NAME="share"
CREDENTIALS_FILE="/etc/marker-sync/credentials"
MOUNT_POINT="/mnt/marker-share"

echo "Создаём папку..."
mkdir -p "$MOUNT_POINT"

echo "Монтируем..."
mount -t cifs "//$SERVER_IP/$SHARE_NAME" "$MOUNT_POINT" \
    -o "credentials=$CREDENTIALS_FILE,vers=2.0,ro"

echo "Exit code: $?"
echo "Содержимое:"
ls "$MOUNT_POINT/" 2>&1 | head -5

echo "Отмонтируем..."
umount "$MOUNT_POINT"
EOF

sudo chmod +x /tmp/test-mount.sh
sudo /tmp/test-mount.sh
