# Get5 Web Stats (G5WS)
Sourcemod plugin for G5API.

This plugin is to be used in conjuction with [G5API](https://github.com/PhlexPlexico/G5API). It includes various changes, such as tracking vetoes to a database, and uploading the demo of a match once the match is completed.

# Requirements
In order to compile this and use it on a server, you must have:

- [REST In PAWN](https://github.com/ErikMinekus/sm-ripext)

Once these requirements are met, you may build the plugin with `spcomp`.  
If you do not wish to build from source, the latest version of the 
plugin is both available in the releases [G5WS](https://github.com/PhlexPlexico/G5WS/releases/download/latest/get5_apistats.smx).

# FAQ
Q. My install isn't working!  
A. Make sure you have installed the [REST In PAWN](https://github.com/ErikMinekus/sm-ripext) extension on your server. This library makes the HTTP calls to the web server.

Q. I'm getting "Unexpected JSON at line X"  
A. This is a get5 issue on the game server. Please make sure all requirements are met for installing get5.

~~Q. The JSON response is empty on the web server.  
A. This has been a documented issue with Windows Game Servers. The only fix for this for RiP is to ensure that your G5API webserver is currently running over **HTTPS**. HTTP will not work in this case.
The extension REST In PAWN is required in order to run this.~~

~~Q. Why not use SteamWorks Extension?  
A. The main reason is due to the fact that RiP has a JSON library included, and we can send octet-streams as well. This enables demo uploads directly to the server without any additional libraries used.~~

Q. What is this stupid support message?  
A. In order to get the message out about match management systems, a donation message is loaded each half. If you would like to disable it, simply put `get5_api_support_message 0` in your `live.cfg` :)

Q. Why are my demos not uploading?  
A. Make sure in your `warmup.cfg` and `live.cfg` have `get5_upload_demos 1` set. Or put it in your `server.cfg`.

Q. Why can't I use PNG files?  
A. In order to get these, you must set `get5_use_svg 0` in your `server.cfg` to make use of PNG formatted team logos.

## Thanks To
[splewis](https://github.com/splewis) for the initial plugin. It was stated that this could be used as a modified product, or forked. 
[rpkaul](https://github.com/rpkaul) for letting me relentlessly bother him with testing.