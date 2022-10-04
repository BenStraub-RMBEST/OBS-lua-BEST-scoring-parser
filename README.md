# OBS-lua-BEST-scoring-parser
A Lua script for OBS to parse the match and timer information from the BEST Robotics PC Scoring Manager.

**Note: this script was written for OBS v28.** It uses a new API that is only available in **v28** and later.

## Installing the script:

### Prereq install
First, you'll need to install the pre-requisite libraries to OBS's lua search path. The libraries you'll need to go download are:
* [luajit-request](https://github.com/LPGhatguy/luajit-request) - A library for doing http requests using only luajit (natively included in OBS Lua)
* [htmlparser](https://github.com/msva/lua-htmlparser) - A library for doing simple HTML parsing

Steps:
* Download the source code for the above prereq libraries.
* Create the OBS lua library folder if it doesn't already exist. It should be something like:
  C:\Program Files\obs-studio\bin\64bit\lua
  The path may differ depending on where you installed OBS, but it should be <install-path>\bin\64bit\lua. That "lua" folder is the part that may not exist that you need to create
* Copy the necessary source files from the prereq libraries to the lua folder:
  - For luajit-request: copy the "luajit-request" folder into OBS's lua folder.
  - For htmlparser: from the "src" folder, copy "htmlparser.lua" and the "htmlparser" folder into OBS's lua folder.

### Load the OBS-lua-BEST-scoring-parser script into OBS:
Steps:
* In OBS, go to "Tools" > "Scripts" to open the Scripts window.
* Click the plus (+) in the lower left corner of the Scripts window. Navigate to this repository and select the "obs-best-scoring-parser.lua" file.

## Configuring the script:
I tried to make all of the parameters pretty obvious and self-explanatory. I may come back and update this README later with more details on the individual script parameters.

## Troubleshooting
A small amount of debug information is printed to the Script Log, which you can get to by clicking the "Script Log" button from the Scripts window. If you know a bit about lua and OBS's lua library, you can add your own debugging information and try to debug your issues yourself. Also feel free to reach out to me (Ben Straub) at my BEST email.

## Contributing
I still have a list of additional features and improvements I'd like to make. If you'd like to help or contribute, feel free to reach out to me! You can also submit pull requests with your own changes, but it's probably a good idea to coordinate with me to make sure we're not working on the same thing.
