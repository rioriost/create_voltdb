# create_voltdb

Create [VoltDB](https://www.voltdb.com) on Azure VM with Ultra Disk

![A diagram showing the components this script will deploy.](create_voltdb.png 'Solution Architecture')

This script make a VoltDB cluster consisting of two nodes by default.

Only you need to do is edit at least two lines of the script, 'AZURE_ACCT' and 'RES_LOC' as you want.

After creating the cluster, you need to open tcp/8080 port of one of the nodes in Azure Portal or CLI. All the nodes are connected through VNET with private IP address.

For more details, please see the settings.txt written by the script after creating.

![Web UI.](Screenshots.png 'Screenshots')

## Prerequisites

- Azure CLI: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest
- zsh: version 5.0.2 or later
