# Naming defaults for the NIC26.Automation module. These are EXAMPLE values (the IIC placeholder organisation, the lab
# token and the East US short code). Nothing in the code carries them.
#
# Change them for your own environment in any one of three ways (first match wins):
#   1. set org / token / location_short in your environment file (the config loader and the name catalog use those first);
#   2. set the environment variables NIC26_ORG, NIC26_TOKEN and NIC26_REGION;
#   3. edit this file.
#
# Rules (design/shared/naming-standard.md): Org 2-8 lower-case alphanumerics; Token 3-8; Region 2-8.
@{
    Org    = 'iic'
    Token  = 'nic26'
    Region = 'eus'
}
