set dotenv-load

[private]
alias husarnet := connect-husarnet
[private]
alias flash := flash-firmware
[private]
alias rosbot := start-rosbot
[private]
alias pc := start-pc
[private]
alias teleop := run-teleop
[private]
alias teleop-docker := run-teleop-docker
[private]
alias joy := run-joy

[private]
default:
  @just --list --unsorted

_install-rsync:
    #!/bin/bash
    if ! command -v rsync &> /dev/null; then \
        if [ "$EUID" -ne 0 ]; then \
            echo "Please run as root to install dependencies"; \
            exit 1; \
        fi

        sudo apt update && sudo apt install -y rsync
    fi

_install-yq:
    #!/bin/bash
    if ! command -v /usr/bin/yq &> /dev/null; then \
        if [ "$EUID" -ne 0 ]; then \
            echo "Please run as root to install dependencies"; \
            exit 1; \
        fi

        YQ_VERSION=v4.35.1
        ARCH=$(arch)

        if [ "$ARCH" = "x86_64" ]; then \
            YQ_ARCH="amd64"; \
        elif [ "$ARCH" = "aarch64" ]; then \
            YQ_ARCH="arm64"; \
        else \
            YQ_ARCH="$ARCH"; \
        fi

        curl -L https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH} -o /usr/bin/yq
        chmod +x /usr/bin/yq
        echo "yq installed successfully!"
    fi

# connect to Husarnet VPN network
connect-husarnet joincode hostname:
    #!/bin/bash
    if [ "$EUID" -ne 0 ]; then \
        echo "Please run as root"; \
        exit; \
    fi
    if ! command -v husarnet > /dev/null; then \
        echo "Husarnet is not installed. Installing now..."; \
        curl https://install.husarnet.com/install.sh | sudo bash; \
    fi
    husarnet join {{joincode}} {{hostname}}

# flash the proper firmware for STM32 microcontroller in ROSbot 2R / 2 PRO
flash-firmware: _install-yq
    #!/bin/bash
    if [ "$EUID" -ne 0 ]; then
        echo "Stopping all running containers"
        docker ps -q | xargs -r docker stop

        echo "Flashing the firmware for STM32 microcontroller in ROSbot"
        docker run \
            --rm -it --privileged \
            --mount type=bind,source=/dev/ttyUSBDB,target=/dev/ttyUSBDB \
            $(yq .services.rosbot.image compose.yaml) \
            flash-firmware.py -p /dev/ttyUSBDB # todo
            # ros2 run rosbot_utils flash_firmware
    else
        echo "Please run \"just flash-firmware\" as non-root user"
    fi

# start containers on ROSbot 2R / 2 PRO
start-rosbot:
    #!/bin/bash
    docker compose up

# start containers on PC
start-pc:
    xhost +local:docker
    docker compose -f compose.pc.yaml up rviz ros2router

# run teleop_twist_keybaord (host)
run-teleop:
    #!/bin/bash
    export FASTRTPS_DEFAULT_PROFILES_FILE=$(pwd)/shm-only.xml
    ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r __ns:=/${ROBOT_NAMESPACE}

# run teleop_twist_keybaord (inside rviz2 container)
run-teleop-docker:
    docker compose -f compose.pc.yaml exec rviz /bin/bash -c "/ros_entrypoint.sh ros2 run teleop_twist_keyboard teleop_twist_keyboard --ros-args -r __ns:=/${ROBOT_NAMESPACE}"

# enable the F710 gemapad (connected to your PC) to control ROSbot
run-joy:
    docker compose -f compose.pc.yaml up joy2twist

# copy repo content to remote host with 'rsync' and watch for changes
sync hostname="${ROBOT_NAMESPACE}" password="husarion": _install-rsync
    #!/bin/bash
    if [ "$EUID" -ne 0 ]; then
        sshpass -p "husarion" rsync -vRr --delete ./ husarion@{{hostname}}:/home/husarion/${PWD##*/}
        while inotifywait -r -e modify,create,delete,move ./ ; do
            sshpass -p "{{password}}" rsync -vRr --delete ./ husarion@{{hostname}}:/home/husarion/${PWD##*/}
        done
    else
        echo "Please run \"just sync\" as non-root user"
    fi

# source ROS 2 workspace
config:
    #!/bin/bash
    echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="03e7", MODE="0666"' | sudo tee /etc/udev/rules.d/80-movidius.rules
    sudo udevadm control --reload-rules && sudo udevadm trigger