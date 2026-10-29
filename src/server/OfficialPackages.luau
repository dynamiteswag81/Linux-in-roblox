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
	{
		name = "lolcat",
		version = "1.0",
		description = "Rainbow-colors whatever you pipe into it. Try: brickfetch | lolcat",
		files = {
			["usr/bin/lolcat"] = [==[#!/bin/sh
# lolcat - rainbow text (busybox awk)
cat "$@" | awk 'BEGIN { split("31 33 32 36 34 35", c, " ") }
{
	out = ""
	for (i = 1; i <= length($0); i++) {
		out = out "\033[1;" c[int((i + NR * 2) / 3) % 6 + 1] "m" substr($0, i, 1)
	}
	print out "\033[0m"
}'
]==],
		},
	},
	{
		name = "banner",
		version = "1.0",
		description = "Prints words in big block letters. Usage: banner HELLO",
		files = {
			["usr/bin/banner"] = [==[#!/bin/sh
# banner - big letters (5 rows per letter)
[ $# -gt 0 ] || { echo "usage: banner <text>"; exit 1; }
echo "$*" | awk '
BEGIN {
	f["A"]=" ### |#   #|#####|#   #|#   #"; f["B"]="#### |#   #|#### |#   #|#### "
	f["C"]=" ####|#    |#    |#    | ####"; f["D"]="#### |#   #|#   #|#   #|#### "
	f["E"]="#####|#    |#### |#    |#####"; f["F"]="#####|#    |#### |#    |#    "
	f["G"]=" ####|#    |#  ##|#   #| ####"; f["H"]="#   #|#   #|#####|#   #|#   #"
	f["I"]="#####|  #  |  #  |  #  |#####"; f["J"]="    #|    #|    #|#   #| ### "
	f["K"]="#   #|#  # |###  |#  # |#   #"; f["L"]="#    |#    |#    |#    |#####"
	f["M"]="#   #|## ##|# # #|#   #|#   #"; f["N"]="#   #|##  #|# # #|#  ##|#   #"
	f["O"]=" ### |#   #|#   #|#   #| ### "; f["P"]="#### |#   #|#### |#    |#    "
	f["Q"]=" ### |#   #|# # #|#  # | ## #"; f["R"]="#### |#   #|#### |#  # |#   #"
	f["S"]=" ####|#    | ### |    #|#### "; f["T"]="#####|  #  |  #  |  #  |  #  "
	f["U"]="#   #|#   #|#   #|#   #| ### "; f["V"]="#   #|#   #|#   #| # # |  #  "
	f["W"]="#   #|#   #|# # #|## ##|#   #"; f["X"]="#   #| # # |  #  | # # |#   #"
	f["Y"]="#   #| # # |  #  |  #  |  #  "; f["Z"]="#####|   # |  #  | #   |#####"
	f["0"]=" ### |#  ##|# # #|##  #| ### "; f["1"]="  #  | ##  |  #  |  #  | ### "
	f["2"]=" ### |#   #|  ## | #   |#####"; f["3"]="#### |    #| ### |    #|#### "
	f["4"]="#   #|#   #|#####|    #|    #"; f["5"]="#####|#    |#### |    #|#### "
	f["6"]=" ### |#    |#### |#   #| ### "; f["7"]="#####|    #|   # |  #  |  #  "
	f["8"]=" ### |#   #| ### |#   #| ### "; f["9"]=" ### |#   #| ####|    #| ### "
	f[" "]="     |     |     |     |     "; f["!"]="  #  |  #  |  #  |     |  #  "
	f["?"]=" ### |#   #|  ## |     |  #  "; f["."]="     |     |     |     |  #  "
	f["-"]="     |     |#####|     |     "
}
{
	text = toupper($0)
	for (row = 1; row <= 5; row++) {
		line = ""
		for (i = 1; i <= length(text); i++) {
			ch = substr(text, i, 1)
			if (!(ch in f)) ch = "?"
			split(f[ch], rows, "|")
			line = line rows[row] " "
		}
		print line
	}
}'
]==],
		},
	},
	{
		name = "guess",
		version = "1.0",
		description = "Guess the number between 1 and 100. A tiny game to learn shell scripting from.",
		files = {
			["usr/bin/guess"] = [==[#!/bin/sh
# guess - a number guessing game. Read this file to see how it works!
secret=$(( RANDOM % 100 + 1 ))
tries=0
echo "I'm thinking of a number between 1 and 100."
while true; do
	printf 'Your guess: '
	read -r n || exit 0
	case "$n" in
		''|*[!0-9]*) echo "Numbers only, please."; continue ;;
	esac
	tries=$((tries + 1))
	if [ "$n" -lt "$secret" ]; then
		echo "Higher!"
	elif [ "$n" -gt "$secret" ]; then
		echo "Lower!"
	else
		echo "Yes! It was $secret. You got it in $tries tries."
		exit 0
	fi
done
]==],
		},
	},
	{
		name = "todo",
		version = "1.0",
		description = "A tiny to-do list: todo add <thing>, todo list, todo done <number>.",
		files = {
			["usr/bin/todo"] = [==[#!/bin/sh
# todo - a to-do list kept in ~/.todo
file="$HOME/.todo"
touch "$file"
case "$1" in
	add)
		shift
		[ -n "$*" ] || { echo "usage: todo add <thing to do>"; exit 1; }
		echo "$*" >> "$file"
		echo "Added: $*"
		;;
	done)
		[ -n "$2" ] || { echo "usage: todo done <number>"; exit 1; }
		item=$(sed -n "${2}p" "$file")
		[ -n "$item" ] || { echo "No item $2"; exit 1; }
		sed -i "${2}d" "$file"
		echo "Done: $item"
		;;
	""|list)
		if [ -s "$file" ]; then
			nl -w2 -s'. ' "$file"
		else
			echo "Nothing to do! Add something with: todo add <thing>"
		fi
		;;
	*)
		echo "usage: todo [list] | todo add <thing> | todo done <number>"
		;;
esac
]==],
		},
	},
	{
		name = "snake",
		version = "1.0",
		description = "The classic snake game, written in pure shell. Arrow keys or WASD, q to quit.",
		readme = [[
Eat the * to grow. Don't hit the walls or yourself.
Controls: arrow keys or W/A/S/D. Q quits.
The whole game is one shell script: cat /usr/bin/snake
]],
		files = {
			["usr/bin/snake"] = [==[#!/bin/sh
# snake - the classic game in busybox hush
W=40; H=18
saved=$(stty -g)
cleanup() { stty "$saved"; printf '\033[0m\033[?25h\033[%d;1H\n' $((H + 4)); }
trap 'cleanup; exit' INT TERM
stty -icanon -echo min 0 time 1
printf '\033[?25l\033[2J\033[H'
# Walls
row=1
while [ $row -le $((H + 2)) ]; do
	if [ $row -eq 1 ] || [ $row -eq $((H + 2)) ]; then
		line="+"; i=0; while [ $i -lt $W ]; do line="$line-"; i=$((i + 1)); done
		printf '\033[%d;1H%s+' $row "$line"
	else
		printf '\033[%d;1H|\033[%d;%dH|' $row $row $((W + 2))
	fi
	row=$((row + 1))
done
x=$((W / 2)); y=$((H / 2)); dx=1; dy=0
body="$x,$y"; len=4; score=0
place_food() {
	while true; do
		fx=$((RANDOM % W + 1)); fy=$((RANDOM % H + 1))
		case " $body " in *" $fx,$fy "*) ;; *) break ;; esac
	done
	printf '\033[%d;%dH\033[1;33m*\033[0m' $((fy + 1)) $((fx + 1))
}
place_food
while true; do
	key=""
	read -r -n 1 key
	if [ "$key" = "$(printf '\033')" ]; then
		read -r -n 1 key; read -r -n 1 key
		case "$key" in A) key=w ;; B) key=s ;; C) key=d ;; D) key=a ;; esac
	fi
	case "$key" in
		w|W) [ $dy -ne 1 ] && { dx=0; dy=-1; } ;;
		s|S) [ $dy -ne -1 ] && { dx=0; dy=1; } ;;
		a|A) [ $dx -ne 1 ] && { dx=-1; dy=0; } ;;
		d|D) [ $dx -ne -1 ] && { dx=1; dy=0; } ;;
		q|Q) break ;;
	esac
	x=$((x + dx)); y=$((y + dy))
	if [ $x -lt 1 ] || [ $x -gt $W ] || [ $y -lt 1 ] || [ $y -gt $H ]; then break; fi
	case " $body " in *" $x,$y "*) break ;; esac
	body="$body $x,$y"
	printf '\033[%d;%dH\033[1;32m@\033[0m' $((y + 1)) $((x + 1))
	if [ $x -eq $fx ] && [ $y -eq $fy ]; then
		len=$((len + 2)); score=$((score + 10)); place_food
	fi
	set -- $body
	if [ $# -gt $len ]; then
		tail=$1
		printf '\033[%d;%dH ' $((${tail#*,} + 1)) $((${tail%,*} + 1))
		body="${body#* }"
	fi
	printf '\033[%d;1HScore: %d   (q quits)' $((H + 3)) $score
done
cleanup
echo "Game over! Score: $score"
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
