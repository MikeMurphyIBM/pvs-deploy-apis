This automation script is designed to execute the initial steps for migrating an IBM i workload via snapshot 
restoration for the purposes of performing a backup operation, and is 1 of 3 in the series.


Required Utilities:

-ibmcloud CLI and the power-iaas plugin.
-jq for JSON processing.

Script Outline

1.  Define Environment Variables (Region/Zone/Subnet/Private IP/Image ID/API Key)
2.  Authenticate to IBM Cloud/Request IAM Token
3.  Build Payload for IBMi LPAR
4.  Create IBMi LPAR in Shutoff State
5.  Success Check
