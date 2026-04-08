-- Paths injected by setup.sh at compile time
property spotdlPath : "__SPOTDL_PATH__"
property ytdlpPath : "__YTDLP_PATH__"

on run
	try
		set dialogURL to display dialog "Paste a Spotify or YouTube playlist URL:" ¬
			default answer "" ¬
			buttons {"Cancel", "⚙ Spotify Settings", "Download"} ¬
			default button "Download" ¬
			cancel button "Cancel" ¬
			with title "Music Downloader"

		set inputURL to text returned of dialogURL
		set clickedBtn to button returned of dialogURL

		if clickedBtn is "⚙ Spotify Settings" then
			my showSpotifySettings()
			return
		end if

		if inputURL is "" then
			display alert "Error" message "URL cannot be empty." buttons {"OK"} as warning
			return
		end if

		-- Detect source
		set isSpotify to (inputURL contains "spotify.com")
		set isYouTube to (inputURL contains "youtube.com" or inputURL contains "youtu.be")

		if not isSpotify and not isYouTube then
			display alert "Unsupported URL" ¬
				message "Please enter a Spotify or YouTube playlist URL." ¬
				buttons {"OK"} as warning
			return
		end if

		if isSpotify then
			my handleSpotify(inputURL)
		else
			my handleYouTube(inputURL)
		end if

	on error errorMsg number errorNum
		if errorNum is not -128 then
			display alert "An error occurred" message errorMsg buttons {"OK"} as critical
		end if
	end try
end run


on showSpotifySettings()
	set homeDir to POSIX path of (path to home folder)
	set configPath to homeDir & ".spotdl/config.json"

	-- Read current client_id
	set currentId to ""
	try
		set currentId to do shell script "python3 -c \"import json; d=json.load(open('" & configPath & "')); print(d.get('client_id',''))\" 2>/dev/null"
	end try

	-- Show masked client_id
	set maskedId to "(not set)"
	if length of currentId > 8 then
		set maskedId to (text 1 thru 8 of currentId) & "••••••••"
	else if currentId is not "" then
		set maskedId to currentId & "••••"
	end if

	set settingsChoice to display alert "Spotify API Credentials" ¬
		message "Current Client ID: " & maskedId & return & return & ¬
		"If downloads fail with an authentication error, your Spotify app credentials may have been revoked or reset." & return & return & ¬
		"Click 'Edit Credentials' to enter new ones, or 'Open Dashboard' to get them from developer.spotify.com." ¬
		buttons {"Cancel", "Open Dashboard", "Edit Credentials"} ¬
		default button "Edit Credentials"

	set choiceBtn to button returned of settingsChoice

	if choiceBtn is "Open Dashboard" then
		open location "https://developer.spotify.com/dashboard"
		-- Continue to edit after opening dashboard
		set choiceBtn to "Edit Credentials"
	end if

	if choiceBtn is "Edit Credentials" then
		set idDialog to display dialog "Enter your Spotify Client ID:" ¬
			default answer currentId ¬
			buttons {"Cancel", "Next"} ¬
			default button "Next" ¬
			cancel button "Cancel" ¬
			with title "Spotify Credentials — Step 1/2"
		set newClientId to text returned of idDialog

		set secretDialog to display dialog "Enter your Spotify Client Secret:" ¬
			default answer "" ¬
			buttons {"Cancel", "Save"} ¬
			default button "Save" ¬
			cancel button "Cancel" ¬
			with title "Spotify Credentials — Step 2/2"
		set newClientSecret to text returned of secretDialog

		my saveCredentials(homeDir, configPath, newClientId, newClientSecret)

		display alert "Credentials Saved" ¬
			message "Your Spotify credentials have been updated and the auth cache has been cleared." & return & return & ¬
			"The app will open a browser to re-authenticate on your next Spotify download." ¬
			buttons {"OK"} default button "OK"
	end if
end showSpotifySettings


-- Save client_id + client_secret directly into spotdl's config.json
-- and wipe all spotipy token caches so stale refresh tokens can't cause 86400s bans.
on saveCredentials(homeDir, configPath, clientId, clientSecret)
	do shell script "mkdir -p " & quoted form of (homeDir & ".spotdl")
	-- Update config.json in-place with Python (reliable, no async issues unlike spotdl save)
	set pyCode to "import json; d=json.load(open('" & configPath & "')); d['client_id']='" & clientId & "'; d['client_secret']='" & clientSecret & "'; open('" & configPath & "','w').write(json.dumps(d,indent=2))"
	do shell script "python3 -c " & quoted form of pyCode
	-- Wipe ALL known spotipy token cache locations so the next run does a fresh OAuth flow
	do shell script "rm -f " & quoted form of (homeDir & ".spotdl/.spotipy") & "; rm -f " & quoted form of (homeDir & ".cache") & "; rm -f /tmp/.spotipy 2>/dev/null; true"
end saveCredentials


on handleSpotify(playlistURL)
	set homeDir to POSIX path of (path to home folder)
	set configPath to homeDir & ".spotdl/config.json"

	-- Check if both Spotify credentials are configured (and not the default spotdl shared ones)
	set hasCredentials to false
	set defaultId to "5f573c9620494bae87890c0f08a60293"
	try
		set checkCmd to "python3 -c \"import json,sys; d=json.load(open('" & configPath & "')); cid=d.get('client_id',''); cs=d.get('client_secret',''); sys.exit(0 if cid and len(cid)>5 and cs and len(cs)>5 and cid!='" & defaultId & "' else 1)\" 2>/dev/null && echo YES || echo NO"
		set credCheck to do shell script checkCmd
		if credCheck is "YES" then
			set hasCredentials to true
		end if
	end try

	if not hasCredentials then
		-- First-time Spotify setup (or default credentials detected)
		display alert "Spotify Setup Required" ¬
			message "To download from Spotify, you need a free Spotify Developer account." & return & return & ¬
			"Click 'Open Dashboard' to create an app and get your API credentials." ¬
			buttons {"Open Dashboard"} ¬
			default button "Open Dashboard"

		open location "https://developer.spotify.com/dashboard"

		display alert "Create a Spotify App" ¬
			message "In the dashboard:" & return & ¬
			"1. Click 'Create app'" & return & ¬
			"2. Fill in any name and description" & return & ¬
			"3. Add both Redirect URIs:" & return & ¬
			"   • http://127.0.0.1:9900/" & return & ¬
			"   • http://127.0.0.1:9900" & return & ¬
			"4. Check 'Web API'" & return & ¬
			"5. Go to Settings → copy Client ID and Client Secret" & return & return & ¬
			"Then click OK and enter your credentials." ¬
			buttons {"OK"} default button "OK"

		set idDialog to display dialog "Enter your Spotify Client ID:" ¬
			default answer "" ¬
			buttons {"Cancel", "Next"} ¬
			default button "Next" ¬
			cancel button "Cancel" ¬
			with title "Spotify Setup — Step 1/2"
		set clientId to text returned of idDialog

		set secretDialog to display dialog "Enter your Spotify Client Secret:" ¬
			default answer "" ¬
			buttons {"Cancel", "Save & Download"} ¬
			default button "Save & Download" ¬
			cancel button "Cancel" ¬
			with title "Spotify Setup — Step 2/2"
		set clientSecret to text returned of secretDialog

		my saveCredentials(homeDir, configPath, clientId, clientSecret)
	end if

	-- Build output path: ~/Music/music-downloader/<playlist-name>/<pos> - <artists> - <title>.mp3
	set musicDir to POSIX path of (path to music folder)
	set outputTemplate to musicDir & "music-downloader/{list-name}/{list-position} - {artists} - {title}.{output-ext}"

	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		spotdlPath & " --config --user-auth download " & quoted form of playlistURL & ¬
		" --bitrate 320k --format mp3 --threads 4" & ¬
		" --output " & quoted form of outputTemplate & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleSpotify


on handleYouTube(videoURL)
	set musicDir to POSIX path of (path to music folder)

	-- Detect playlist vs single video
	set isPlaylist to (videoURL contains "list=")

	if isPlaylist then
		-- %(playlist_title)s resolved automatically by yt-dlp
		set outputTemplate to musicDir & "music-downloader/%(playlist_title)s/%(title)s.%(ext)s"
	else
		-- Single video → ~/Music/music-downloader/YouTube/<uploader> - <title>.mp3
		set outputTemplate to musicDir & "music-downloader/YouTube/%(uploader)s - %(title)s.%(ext)s"
	end if

	set cmd to "source ~/.zshrc 2>/dev/null; source ~/.zprofile 2>/dev/null; " & ¬
		ytdlpPath & " --extract-audio --audio-format mp3" & ¬
		" --postprocessor-args \"ffmpeg:-b:a 320k\"" & ¬
		" --yes-playlist --add-metadata" & ¬
		" --cookies-from-browser safari" & ¬
		" -o " & quoted form of outputTemplate & ¬
		" " & quoted form of videoURL & ¬
		"; echo ''; echo '✅ Download complete. You can close this window.'"

	tell application "Terminal"
		activate
		do script cmd
	end tell
end handleYouTube
