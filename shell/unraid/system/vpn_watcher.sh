#!/bin/bash

container_name=""
isp_ip=""

while true; do
	vpn_ip=$(docker exec "${container_name}" bash -c 'curl -s https://api.ipify.org')
	if [[ $? -ne 0 ]]; then
		echo "Container ${container_name} not running, sleeping for 5 seconds..."
		sleep 5s
		continue
	fi
	if [[ "${vpn_ip}" == "${isp_ip}" ]]; then
		echo "!!IMPORTANT VPN IP leakage occurred!!"
		echo "Shutting down Docker container ${container_name} to prevent further leakage..."
		docker stop "${container_name}"
		echo "Sending email with details of leakage..."
		/usr/local/emhttp/webGui/scripts/notify -i normal -s "IMPORTANT VPN IP leakage occurred" -d "$(date)-VPN IP ${vpn_ip} and ISP IP ${isp_ip} match, this means we have potential IP Leakage for container ${container_name}."
		echo "Sleeping for 60 seconds to prevent spamming e-mail inbox..."
		sleep 59s
	else
		echo "$(date)-VPN IP ${vpn_ip} and ISP IP ${isp_ip} are different, no leakage has occurred."
	fi
	sleep 1s
done
