--!strict
--[[
	Packages that ship with the game, so the Community Workshop has something
	in it from day one. They are ordinary brick packages (BRICK manifest +
	files/), built into tar archives when the server starts.

	Everything here is a shell or awk script: the guest has no C compiler.
]]

local LinuxVM = require(script.Parent.Deps) :: any
local Tar = require(LinuxVM.Util.Tar)

type PackageDef = {
	name: string,
	version: string,
	description: string,
	readme: string?,
	depends: { string }?,
	files: { [string]: string }, -- path (without leading /) -> contents; all made executable if under bin/
	install: string?,
}

local DEFS: { PackageDef } = {
	{
		name = "hello",
		version = "1.0",
		description = "The classic first program. Also an example of how a package is put together.",
		readme = [[
hello prints a greeting. Its source is a tiny shell script:

    cat /usr/bin/hello

Make your own package:

    brick new mytool        # creates mytool/BRICK and mytool/files/
    vi mytool/files/usr/bin/mytool
    brick publish mytool    # share it in the Community Workshop
]],
		files = {
			["usr/bin/hello"] = [==[#!/bin/sh
name="${1:-$(whoami)}"
echo "Hello, $name! Welcome to $(hostname), running Brick Linux."
]==],
		},
	},
	{
		name = "cowsay",
		version = "1.0",
		description = "A cow that says whatever you tell it. Try: fortune | cowsay",
		files = {
			["usr/bin/cowsay"] = [==[#!/bin/sh
# cowsay - a talking cow (busybox awk edition)
if [ $# -gt 0 ]; then
	printf '%s\n' "$*"
else
	cat
fi | awk -v width=40 '
{ text = text (NR > 1 ? " " : "") $0 }
END {
	n = split(text, words, " ")
	count = 0; line = ""
	for (i = 1; i <= n; i++) {
		if (line != "" && length(line) + 1 + length(words[i]) > width) { lines[++count] = line; line = words[i] }
		else line = (line == "" ? words[i] : line " " words[i])
	}
	if (line != "" || count == 0) lines[++count] = line
	max = 0
	for (i = 1; i <= count; i++) if (length(lines[i]) > max) max = length(lines[i])
	top = ""; bottom = ""
	for (i = 0; i < max + 2; i++) { top = top "_"; bottom = bottom "-" }
	print " " top
	for (i = 1; i <= count; i++) {
		if (count == 1) { l = "<"; r = ">" }
		else if (i == 1) { l = "/"; r = "\\" }
		else if (i == count) { l = "\\"; r = "/" }
		else { l = "|"; r = "|" }
		printf "%s %-" max "s %s\n", l, lines[i], r
	}
	print " " bottom
	print "        \\   ^__^"
	print "         \\  (oo)\\_______"
	print "            (__)\\       )\\/\\"
	print "                ||----w |"
	print "                ||     ||"
}'
]==],
		},
	},
	{
		name = "fortune",
		version = "1.0",
		description = "Prints a random saying. Add your own to /usr/share/fortune/brick.",
		files = {
			["usr/bin/fortune"] = [==[#!/bin/sh
file="${1:-/usr/share/fortune/brick}"
[ -r "$file" ] || { echo "fortune: no fortunes in $file" >&2; exit 1; }
count=$(grep -c . "$file")
[ "$count" -gt 0 ] || exit 1
pick=$(( (RANDOM % count) + 1 ))
grep . "$file" | sed -n "${pick}p"
]==],
			["usr/share/fortune/brick"] = [==[There is no place like 127.0.0.1.
This computer is a RISC-V CPU, emulated in Luau, running inside a game. It's turtles all the way down.
To exit vi, press Esc on the on-screen keyboard, then type :q and Enter.
It works on my machine. Your machine is in my machine.
rm -rf / is a great way to test your backups.
The best way to learn Linux is to break it and fix it again.
A watched pot never boils. A watched kernel never finishes compiling.
Real programmers count from 0.
Have you tried turning it off and on again?
There are 10 kinds of people: those who understand binary and those who don't.
Every byte you type travels through a Roblox server to reach your own CPU.
Sharing is caring: brick publish your best scripts.
Ping your friends: ping <their username>.
"Talk is cheap. Show me the code." - Linus Torvalds
If at first you don't succeed, call it version 1.0.
]==],
		},
	},
	{
		name = "sl",
		version = "1.0",
		description = "A steam locomotive drives across your screen. For when you mistype ls.",
		files = {
			["usr/bin/sl"] = [==[#!/bin/sh
# sl - steam locomotive
cols=80
l1='      ====        ________                ___________ '
l2='  _D _|  |_______/        \__I_I_____===__|_________| '
l3='   |(_)---  |   H\________/ |   |        =|___ ___|   '
l4='   /     |  |   H  |  |     |   |         ||_| |_||   '
l5='  |      |  |   H  |__--------------------| [___] |   '
l6='  | ________|___H__/__|_____/[][]~\_______|       |   '
l7='  |/ |   |-----------I_____I [][] []  D   |=======|__ '
l8='__/ =| o |=-~~\  /~~\  /~~\  /~~\ ____Y___________|__ '
l9=' |/-=|___|=    ||    ||    ||    |_____/~\___/        '
l10='  \_/      \O=====O=====O=====O_/      \_/            '
width=${#l1}
printf '\033[?25l\033[2J'
trap 'printf "\033[?25h\033[0m\n"; exit' INT
x=$cols
while [ $x -gt $((0 - width)) ]; do
	row=7
	for line in "$l1" "$l2" "$l3" "$l4" "$l5" "$l6" "$l7" "$l8" "$l9" "$l10"; do
		if [ $x -ge 0 ]; then
			start=0; col=$((x + 1)); len=$((cols - x))
		else
			start=$((0 - x)); col=1; len=$cols
		fi
		printf '\033[%d;%dH%s' $row $col "${line:$start:$len}"
		row=$((row + 1))
	done
	x=$((x - 2))
	usleep 30000
done
printf '\033[2J\033[H\033[?25h'
]==],
		},
	},
	{
		name = "matrix",
		version = "1.0",
		description = "Green characters rain down your screen. Press Ctrl+C to wake up.",
		files = {
			["usr/bin/matrix"] = [==[#!/bin/sh
# matrix - digital rain
chars='abcdefghijklmnopqrstuvwxyz0123456789@#$%&*+=<>?'
n=${#chars}
printf '\033[?25l\033[2J\033[40m'
trap 'printf "\033[0m\033[2J\033[H\033[?25h"; exit' INT
while true; do
	i=0
	while [ $i -lt 12 ]; do
		c=${chars:$((RANDOM % n)):1}
		if [ $((RANDOM % 4)) -eq 0 ]; then color='1;37'; else color='32'; fi
		printf '\033[%d;%dH\033[%sm%s' $((RANDOM % 25 + 1)) $((RANDOM % 80 + 1)) "$color" "$c"
		i=$((i + 1))
	done
	printf '\033[%d;%dH ' $((RANDOM % 25 + 1)) $((RANDOM % 80 + 1))
	usleep 20000
done
]==],
		},
	},
	{
		name = "webserver",
		version = "1.0",
		description = "Host a website on your computer that other players can visit with browse or wget.",
		readme = [[
Installs a web server that starts with your computer and serves /www.

    vi /www/index.html          # edit your page
    /etc/init.d/S50httpd restart

Other players visit it with:  browse <your computer name>
]],
		files = {
			["etc/init.d/S50httpd"] = [==[#!/bin/sh
# Starts busybox httpd serving /www on port 80.
case "$1" in
	start)
		mkdir -p /www
		httpd -h /www -p 80 && echo "httpd: serving /www on port 80"
		;;
	stop)
		killall httpd 2>/dev/null
		;;
	restart)
		"$0" stop
		sleep 1
		"$0" start
		;;
	*)
		echo "usage: $0 start|stop|restart"
		;;
esac
]==],
			["www/index.html"] = [==[<html>
<head><title>My Brick Linux page</title></head>
<body>
<h1>Welcome to my computer!</h1>
<p>This page is served by busybox httpd on Brick Linux, inside Roblox.</p>
<p>Edit /www/index.html to change it.</p>
</body>
</html>
]==],
		},
		install = "/etc/init.d/S50httpd start",
	},
	{
		name = "browse",
		version = "1.0",
		description = "A tiny text web browser for pages hosted on other players' computers.",
		files = {
			["usr/bin/browse"] = [==[#!/bin/sh
# browse <host>[/path] - fetch a page and show it as text
[ -n "$1" ] || { echo "usage: browse <computer>[/path]"; exit 1; }
url="$1"
case "$url" in
	http://*) ;;
	*) url="http://$url" ;;
esac
case "${url#http://}" in
	*/*) ;;
	*) url="$url/" ;;
esac
wget -q -T 10 -O - "$url" 2>/dev/null \
	| sed -e 's/<[Bb][Rr][^>]*>/\n/g' -e 's/<\/[Pp]>/\n/g' -e 's/<[Hh][1-6][^>]*>/\n## /g' \
		-e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' -e 's/&nbsp;/ /g' \
	| sed '/^[[:space:]]*$/N;/^\n$/D' \
	| less -R || echo "browse: could not reach $url"
]==],
		},
	},
	{
		name = "talk",
		version = "1.0",
		description = "Chat with another player's computer over the network (talk <computer>).",
		readme = [[
One player listens, the other connects:

    talk -l              # wait for someone to talk to you
    talk alice           # talk to alice's computer

Type lines and press Enter. Ctrl+C ends the conversation.
]],
		files = {
			["usr/bin/talk"] = [==[#!/bin/sh
port=7777
if [ "$1" = "-l" ]; then
	echo "Waiting for someone to talk to $(hostname) on port $port... (Ctrl+C to stop)"
	exec nc -l -p $port
elif [ -n "$1" ]; then
	echo "Connecting to $1... (Ctrl+C to stop)"
	exec nc "$1" $port
else
	echo "usage: talk -l | talk <computer>"
	exit 1
fi
]==],
		},
	},
}

local OfficialPackages = {}

export type Package = {
	name: string,
	version: string,
	description: string,
	readme: string?,
	tar: string,
	files: { string },
	depends: { string },
}

function OfficialPackages.build(): { Package }
	local out: { Package } = {}
	for _, def in DEFS do
		local manifest = string.format(
			"name=%s\nversion=%s\ndescription=%s\ndepends=%s\n",
			def.name,
			def.version,
			def.description,
			table.concat(def.depends or {}, " ")
		)
		local entries: { Tar.NewEntry } = { { name = "BRICK", data = manifest } }
		if def.readme then
			table.insert(entries, { name = "README", data = def.readme })
		end
		if def.install then
			table.insert(entries, { name = "install.sh", data = "#!/bin/sh\n" .. def.install .. "\n", mode = 493 })
		end
		local paths = {}
		local dirs: { [string]: boolean } = {}
		for path in def.files do
			table.insert(paths, path)
			local parent = string.match(path, "^(.*)/[^/]+$")
			while parent and not dirs[parent] do
				dirs[parent] = true
				parent = string.match(parent, "^(.*)/[^/]+$")
			end
		end
		table.sort(paths)
		local dirList = {}
		for dir in dirs do
			table.insert(dirList, dir)
		end
		table.sort(dirList)
		table.insert(entries, { name = "files", kind = "dir" })
		for _, dir in dirList do
			table.insert(entries, { name = "files/" .. dir, kind = "dir" })
		end
		local listed = {}
		for _, path in paths do
			local executable = string.find(path, "bin/", 1, true) ~= nil or string.find(path, "init.d/", 1, true) ~= nil
			table.insert(entries, {
				name = "files/" .. path,
				data = def.files[path],
				mode = if executable then 493 else 420,
			})
			table.insert(listed, "/" .. path)
		end
		table.insert(out, {
			name = def.name,
			version = def.version,
			description = def.description,
			readme = def.readme,
			tar = Tar.build(entries),
			files = listed,
			depends = def.depends or {},
		})
	end
	return out
end

return OfficialPackages
