#!/bin/bash

set -e

# source in metadata file
source ./docker_metadata.sh

# create variables from metadata stored in sourced in file
name=$(eval echo \$${1}_name)
description=$(eval echo \$${1}_description)
repo=$(eval echo \$${1}_repo)
project=$(eval echo \$${1}_project)
privileged=$(eval echo \$${1}_privileged)
support=$(eval echo \$${1}_support)
category=$(eval echo \$${1}_category)
webui=$(eval echo \$${1}_webui)
mode=$(eval echo \$${1}_mode)
path=$(eval echo \$${1}_path)
port=$(eval echo \$${1}_port)
variable=$(eval echo \$${1}_variable)

# unRAID header template generation
###

# here doc the contents to the xml
cat <<EOF > "./${name}.xml"
<?xml version="1.0"?>
<Container version="2">
  <Name>${name}</Name>
  <Repository>binhex/${repo}</Repository>
  <BaseImage>Arch Linux</BaseImage>
  <Registry>https://registry.hub.docker.com/u/binhex/${repo}/</Registry>
  <Project>${project}</Project>
  <Network>${mode}</Network>
  <Privileged>${privileged}</Privileged>
  <Support>${support}</Support>
  <Overview>${description}</Overview>
  <Category>${category}</Category>
  <WebUI>${webui}</WebUI>
  <TemplateURL>https://github.com/binhex/docker-templates/tree/master/binhex</TemplateURL>
  <Icon>https://raw.githubusercontent.com/binhex/docker-templates/master/binhex/images/${name}-icon.png</Icon>
  <DonateText>If you appreciate my work, then please consider buying me a beer :D</DonateText>
  <DonateLink>https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&amp;hosted_button_id=MM5E27UX6AUU4</DonateLink>
  <DonateImg>https://www.paypal.com/en_US/i/btn/btn_donate_SM.gif</DonateImg>
  <ExtraParams/>
  <DateInstalled></DateInstalled>
  <Description>${description}</Description>
EOF

cat <<EOF >> "./${name}.xml"
  <Networking>
    <Mode>${mode}</Mode>
    <Publish>
EOF

# unRAID v1 template generation
###

# split percent seperated volume v1 mappings
IFS='%' read -ra port_list <<< "${port}"

# loop over list of ports and define as v1 template format
for port_item in "${port_list[@]}"; do

IFS='~' read -ra port_item_list <<< "${port_item}"

cat <<EOF >> "./${name}.xml"
      <Port>
        <HostPort>${port_item_list[0]}</HostPort>
        <ContainerPort>${port_item_list[0]}</ContainerPort>
        <Protocol>${port_item_list[1]}</Protocol>
      </Port>
EOF

done

cat <<EOF >> "./${name}.xml"
    </Publish>
  </Networking>
  <Data>
EOF

# split percent seperated path v1 mappings
IFS='%' read -ra path_list <<< "${path}"

# loop over list of path mappings and define as v1 template format
for path_item in "${path_list[@]}"; do

IFS='~' read -ra path_item_list <<< "${path_item}"

cat <<EOF >> "./${name}.xml"
    <path>
      <HostDir>${path_item_list[0]}</HostDir>
        <ContainerDir>${path_item_list[1]}</ContainerDir>
        <Mode>${path_item_list[2]}</Mode>
    </path>
EOF

done

cat <<EOF >> "./${name}.xml"
  </Data>
  <Environment>
EOF

# split percent seperated path v1 mappings
IFS='%' read -ra variable_list <<< "${variable}"

# loop over list of env vars and define as v1 template format
for variable_item in "${variable_list[@]}"; do

IFS='~' read -ra variable_item_list <<< "${variable_item}"

cat <<EOF >> "./${name}.xml"
    <Variable>
      <Name>${variable_item_list[0]}</Name>
      <Value>${variable_item_list[1]}</Value>
    </Variable>
EOF

done

cat <<EOF >> "./${name}.xml"
  </Environment>
EOF

# unRAID v2 template generation
###

# split percent seperated port v1 mappings
IFS='%' read -ra port_list <<< "${port}"

# loop over list of ports and define as v1 template format
for port_item in "${port_list[@]}"; do

IFS='~' read -ra port_item_list <<< "${port_item}"

cat <<EOF >> "./${name}.xml"
  <Config Name="${port_item_list[2]}" Target="${port_item_list[0]}" Default="${port_item_list[0]}" Mode="${port_item_list[1]}" Description="${port_item_list[2]}" Type="Port" Display="always" Required="true" Mask="false"></Config>
EOF

done

# split percent seperated path v1 mappings
IFS='%' read -ra path_list <<< "${path}"

# loop over list of paths and define as v1 template format
for path_item in "${path_list[@]}"; do

IFS='~' read -ra path_item_list <<< "${path_item}"

cat <<EOF >> "./${name}.xml"
  <Config Name="${path_item_list[3]}" Target="${path_item_list[1]}" Default="${path_item_list[0]}" Mode="${path_item_list[2]}" Description="${path_item_list[3]}" Type="Path" Display="always" Required="true" Mask="false"></Config>
EOF

done

# split percent seperated variable v1 mappings
IFS='%' read -ra variable_list <<< "${variable}"

# loop over list of variables and define as v1 template format
for variable_item in "${variable_list[@]}"; do

IFS='~' read -ra variable_item_list <<< "${variable_item}"

cat <<EOF >> "./${name}.xml"
  <Config Name="${variable_item_list[2]}" Target="${variable_item_list[0]}" Default="${variable_item_list[1]}" Mode="" Description="${variable_item_list[2]}" Type="Variable" Display="always" Required="false" Mask="false"></Config>
EOF

done
 
cat <<EOF >> "./${name}.xml"
</Container>
EOF
