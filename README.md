# simple-router-firewall-configurator
A small scrip that can read in a configuration file and generate the required static DNSMasq configuration and IPTables rules for a simple router &amp; firewall.

# Status
Work in progress.

This script is not finished. Use at own risk. See LICENSE.

# WARNING:
If you improperly configure your router you can lock yourself out, being unable to SSH back in.
Make sure that you read the scripts and understand what is happening before you use it.

# Usage
You can copy the script files only you router machine.
You'll need to have IPTables installed and a DNS and/or DHCP server like DNSMasq.
The example.ini is a example on how to configure 2 nodes and have several ports of them portforwarded through this router.

Make sure that you also update the file names in config.sh to the correct location or your DNS & DHCP server won't load these files.

# LICENSE
See LICENSE file.
