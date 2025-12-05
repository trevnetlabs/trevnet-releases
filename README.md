# trevnet-releases

Great things coming soon!

# Install main server

curl -fsSL https://raw.githubusercontent.com/trevnetlabs/trevnet-releases/main/trevnet-server/install/install.sh | sudo bash

The install script will:

1. Detect your platform (linux/darwin, amd64/arm64)
2. Fetch the latest release metadata
3. Download and install the binary to `/opt/trevnet/trevnet-server` (owned by the `trevnet` user)
4. Create the `trevnet` user and group (if they don't exist)
5. Generate the systemd service file from the template
6. Install and enable the service

### Customization

You can customize the installation by setting environment variables:

```bash
export TREVNET_USER=myuser
export TREVNET_GROUP=mygroup
export TREVNET_INSTALL_DIR=/opt/myapp
export TREVNET_BINARY_INSTALL_DIR=/opt/myapp/bin
export TREVNET_ENV_FILE=/etc/myapp.env
sudo -E ./install/install.sh
```
