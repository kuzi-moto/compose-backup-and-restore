#!/bin/bash

# Parameter 1 - Path to the stack_backup.tar.gz file
backup_file=$1

# Parameter 2 - Directory to put the new stack
stack_dir=$2

# Parameter 3 - (optional) '-test' to test backup in a new compose stack
test_mode=$3

# Set the stack name from the backup file
stack_name=$(basename $backup_file | cut -d "_" -f1)

# Set the output directory
if [ "$test_mode" == "-test" ]; then
    output_dir="$stack_dir/$stack_name"_test
else
    output_dir="$stack_dir/$stack_name"
fi

# Extract the contents of the backup to /tmp
tar -xzf $backup_file -C /tmp

# Extract stack.tar.gz to the output directory
mkdir $output_dir
tar -xzf /tmp/${stack_name}_backup/$stack_name.tar.gz -C $output_dir

# Foreach file in '/tmp/stack_backup/' that starts with 'stack_'
# extract contents to the docker volume with the same name
for file in /tmp/${stack_name}_backup/${stack_name}_*; do
    volume_name=$(basename $file | sed 's/\.tar\.gz$//')

    if [ "$test_mode" == "-test" ]; then
        volume_name="$volume_name"_test
    fi

    if sudo docker volume inspect "$volume_name" >/dev/null 2>&1; then
        echo "Volume $volume_name already exists"
    else
        echo ""
        #sudo docker volume create "$volume_name"
    fi

    #volume_info=$(docker volume inspect "$volume_name")

    if sudo docker volume inspect "$volume_name" | grep -q "\"Mountpoint\": null"; then
        echo "Volume $volume_name is not in use"
    else
        echo "Volume $volume_name is in use"
    fi

    #tar -xzf $file -C /var/lib/docker/volumes/$volume_name/_data
done

rm -rf /tmp/${stack_name}_backup
