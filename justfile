set dotenv-load

[private]
default:
    @just --list --unsorted

[private]
alias husarnet := connect-husarnet
[private]
alias flash := flash-firmware
[private]
alias rosbot := start-rosbot
[private]
alias teleop := run-teleop
[private]
alias foxglove := run-foxglove

[private]
pre-commit:
    #!/bin/bash
    if ! command -v pre-commit &> /dev/null; then
        pip install pre-commit
        pre-commit install
    fi
    pre-commit run -a

# [PC] connect to Husarnet VPN network
connect-husarnet joincode hostname: _run-as-root
    #!/bin/bash
    if ! command -v husarnet > /dev/null; then
        echo "Husarnet is not installed. Installing now..."
        curl https://install.husarnet.com/install.sh | bash
    fi
    husarnet join {{joincode}} {{hostname}}

# [PC] Copy repo content to remote host with 'rsync' and watch for changes
sync hostname="${ROBOT_HOSTNAME}" password="husarion": _install-rsync _run-as-user
    #!/bin/bash
    sshpass -p "{{password}}" rsync -vRr --exclude='.git/' --delete ./ husarion@{{hostname}}:/home/husarion/${PWD##*/}
    while inotifywait -r -e modify,create,delete,move ./ --exclude='.git/' ; do
        sshpass -p "{{password}}" rsync -vRr --exclude='.git/' --delete ./ husarion@{{hostname}}:/home/husarion/${PWD##*/}
    done

# [ROSbot] flash the proper firmware for STM32 microcontroller in ROSbot XL
flash-firmware: _install-yq _run-as-user
    #!/bin/bash
    echo "Stopping all running containers"
    docker ps -q | xargs -r docker stop

    echo "Flashing the firmware for STM32 microcontroller in ROSbot"
    docker run \
        --rm -it \
        --device /dev/ttyUSBDB \
        --device /dev/bus/usb/ \
        $(yq .services.rosbot.image compose.yaml) \
        ros2 run rosbot_xl_utils flash_firmware --port /dev/ttyUSBDB
        # flash-firmware.py -p /dev/ttyUSBDB # todo

# [ROSbot] start containers on a physical ROSbot XL
start-rosbot: _run-as-user
    #!/bin/bash
    docker compose down
    docker compose pull
    docker compose up

# [ROSbot] run teleop_twist_keybaord
run-teleop: _run-as-user
    #!/bin/bash
    source .env.local
    ros2 run teleop_twist_keyboard teleop_twist_keyboard # --ros-args -r __ns:=/${ROBOT_NAMESPACE}

# [PC] run Foxglove Desktop on your PC (optional)
run-foxglove runtime="cpu": _run-as-user
    #!/bin/bash
    if  [[ "{{runtime}}" == "nvidia" ]] ; then
        echo "Docker runtime: nvidia"
        export DOCKER_RUNTIME=nvidia
        export LIBGL_ALWAYS_SOFTWARE=0
    else
        echo "Docker runtime: runc"
        export DOCKER_RUNTIME=runc
        export LIBGL_ALWAYS_SOFTWARE=1
    fi

    xhost +local:docker
    docker compose -f compose.pc.yaml pull
    docker compose -f compose.pc.yaml up foxglove

# [PC] remove Foxglove Desktop launcher from the dock (optional)
remove-launcher:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo rm -rf "$HOME/.local/share/applications/rosbot_xl_telepresence.desktop"
    update-desktop-database "$HOME/.local/share/applications/"
    echo "Application launcher for ROSbot XL telepresence UI removed."
    # Remove application launcher from the Ubuntu dock
    # Extract the current list of favorites
    FAVORITES=$(gsettings get org.gnome.shell favorite-apps)

    # Modify the favorites list to remove the launcher, if present
    NEW_FAVORITES=$(echo $FAVORITES | sed "s/'rosbot_xl_telepresence.desktop',//g" | sed "s/, 'rosbot_xl_telepresence.desktop'//g" | sed "s/'rosbot_xl_telepresence.desktop'//g")

    # Update the list of favorites
    gsettings set org.gnome.shell favorite-apps "$NEW_FAVORITES"

    echo "Application launcher for Foxglove ROSbot XL removed from the dock."

# [PC] install Foxglove Desktop launcher on the dock (optional)
install-launcher:
    #!/usr/bin/env bash
    set -euo pipefail

    LAUNCHER_PATH="$HOME/.local/share/applications/rosbot_xl_telepresence.desktop"
    CURRENT_DIR=$(pwd)
    ICON_PATH="${CURRENT_DIR}/husarion-signet.png"

    echo "[Desktop Entry]
    Version=1.0
    Type=Application
    Name=ROSbot XL telepresence UI
    Exec=gnome-terminal -- bash -c 'just foxglove runc'
    Icon=${ICON_PATH}
    Path=${CURRENT_DIR}
    Terminal=false
    StartupNotify=false" > "${LAUNCHER_PATH}"

    sudo chmod +x "${LAUNCHER_PATH}"
    update-desktop-database "$HOME/.local/share/applications/"
    echo "Application launcher for ROSbot XL telepresence UI installed."

    # Add application launcher to the Ubuntu dock if not already present
    FAVORITES=$(gsettings get org.gnome.shell favorite-apps)
    LAUNCHER_ID="'rosbot_xl_telepresence.desktop'"

    # Check if the launcher is already in the list of favorites
    if [[ $FAVORITES != *"$LAUNCHER_ID"* ]]; then
        # If not, add it to the list
        NEW_FAVORITES=$(echo $FAVORITES | sed -e "s/]$/, $LAUNCHER_ID]/")
        gsettings set org.gnome.shell favorite-apps "$NEW_FAVORITES"
        echo "Application launcher for ROSbot XL telepresence UI added to the dock."
    else
        echo "Application launcher for ROSbot XL telepresence UI is already in the dock."
    fi

_run-as-root:
    #!/bin/bash
    if [ "$EUID" -ne 0 ]; then
        echo -e "\e[1;33mPlease re-run as root user to install dependencies\e[0m"
        exit 1
    fi

_run-as-user:
    #!/bin/bash
    if [ "$EUID" -eq 0 ]; then
        echo -e "\e[1;33mPlease re-run as non-root user\e[0m"
        exit 1
    fi

_install-rsync:
    #!/bin/bash
    if ! command -v rsync &> /dev/null || ! command -v sshpass &> /dev/null || ! command -v inotifywait &> /dev/null; then
        if [ "$EUID" -ne 0 ]; then
            echo -e "\e[1;33mPlease run as root to install dependencies\e[0m"
            exit 1
        fi
        apt install -y rsync sshpass inotify-tools
    fi

_install-yq:
    #!/bin/bash
    if ! command -v /usr/bin/yq &> /dev/null; then
        if [ "$EUID" -ne 0 ]; then
            echo -e "\e[1;33mPlease run as root to install dependencies\e[0m"
            exit 1
        fi

        YQ_VERSION=v4.35.1
        ARCH=$(arch)

        if [ "$ARCH" = "x86_64" ]; then
            YQ_ARCH="amd64"
        elif [ "$ARCH" = "aarch64" ]; then
            YQ_ARCH="arm64"
        else
            YQ_ARCH="$ARCH"
        fi

        curl -L https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH} -o /usr/bin/yq
        chmod +x /usr/bin/yq
        echo "yq installed successfully!"
    fi


# source ROS 2 workspace
config:
    #!/bin/bash
    echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="03e7", MODE="0666"' | sudo tee /etc/udev/rules.d/80-movidius.rules
    sudo udevadm control --reload-rules && sudo udevadm trigger

dds-tunning:
    #!/bin/bash

    # https://fast-dds.docs.eprosima.com/en/latest/fastdds/use_cases/large_data/large_data.html#
    # https://docs.ros.org/en/humble/How-To-Guides/DDS-tuning.html
    sudo sysctl -w net.core.wmem_max=12582912
    sudo sysctl -w net.core.rmem_max=12582912
    sudo sysctl -w net.core.wmem_default=16384000
    sudo sysctl -w net.core.rmem_default=16384000
    sudo sysctl -w net.ipv4.ipfrag_high_thresh=134217728     # (128 MB)
    sudo sysctl -w net.ipv4.ipfrag_time=3
    sudo sysctl -w net.ipv6.ip6frag_time=3 # 3s
    sudo sysctl -w net.ipv6.ip6frag_high_thresh=134217728 # (128 MB)
    sudo ip link set txqueuelen 500 dev hnet0
    sudo ip link set dev hnet0 mtu 1350
    # sudo ip link set dev hnet0 mtu 9000
