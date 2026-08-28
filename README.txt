- scan-notify.sh: is used for bug hunt in vps so it can take so long so i create a script will run it in background, when it done it will create a file outside; 
    - future idea: i can add discord webhook (easy), telegram bot(need server).
    to use tool execute command `nohup ./scan-notify.sh target.com > target_scan.log 2>&1 &`