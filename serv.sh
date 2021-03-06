#!/bin/ksh

set -e

verbose=false
if [ `id -u` = 0 ]; then
        root=/var/www
        port=80
else
        root=~/www
        port=$((13000 + `id -u`))
fi

usage() {
        echo "usage: ${0##*/} [-v] [-d rootdir] [-p port]" >&2
        exit 1
}

while getopts "d:p:v" OPT; do case $OPT in
        d)      root=$OPTARG;;
        p)      port=$OPTARG;;
        v)      verbose=true;;
        *)      usage;;
esac; done
shift $((OPTIND - 1))

$verbose && echo "root directory is $root" >&2


pathToFile="$(pwd)/users.txt"
decodeBase64(){
    cmd=$(echo "$1" | openssl enc -base64 -d)
}

isInUsers(){
    decodeBase64 $1
    decodedData=$cmd
    user="$(echo $decodedData | cut -f1 -d:)"
    password="$(echo $decodedData | cut -f2 -d:)"
    isInFile=false

    while read -r data1 data2
    do
        if [[ $user == $data1 && $password == $data2 ]]; then
            isInFile=true
            break
        fi
    done < "$pathToFile"
}

# It's okay to call this routine multiple times, see $sent
senderr() {
        $sent && return 0

        local text
        case $1 in
        400)    text="Bad request";;
        401)    text="Unauthorized";;
        403)    text="Not allowed";;
        404)    text="Not found";;
        *)      text="Server error"; set -- 500;;
        esac

        sent=true
        echo "HTTP/1.0 $1 $text\r"
        echo "Date: $(date)\r"
        if [[ $1 == 401 ]]; then
            echo "WWW-Authenticate: Basic realm=Access to staging site\r"
        fi
        echo "\r"
}

validate_and_send() {

    if [ x"${1#/}" = x"$1" ]; then
            senderr 400
	return
	fi

	if [[ "$1" == *.cgi* ]]; then
		cgi "$1"
		return
	fi

    local path="${root}$1"
	path=$(readlink -f "$path" || true)
	if [ -z "$path" ]; then
		# hard symlink error: cycle or smth. like that
		senderr 404
	elif [ "x${path#$root}" = "x${path}" ]; then
		$verbose && echo "resulting path lies outside $root: $path" >&2
                senderr 403
        elif ! [ -e "$path" ]; then
                senderr 404
        elif ! [ -r "$path" ]; then
		$verbose && echo "resulting path $path is not readable" >&2
                senderr 403
        elif [ -d "$path" ]; then
		index "$1"
	else
		sendfile "$1"
        fi
}

export_cgi() {

	export SERVER_SOFTWARE="shellweb3"
	export SERVER_NAME=
	export GATEWAY_INTERFACE="CGI/1.1"
	export SERVER_PROTOCOL="HTTP/1.1"
	export SERVER_PORT="$port"
	export REQUEST_METHOD=
	export PATH_INFO=
	export PATH_TRANSLATED=
	export SCRIPT_NAME=
	export QUERY_STRING=
	export REMOTE_HOST=
	export REMOTE_ADDR=
	export AUTH_TYPE=
	export REMOTE_USER=
	export REMOTE_IDENT=
	export CONTENT_TYPE=
	export CONTENT_LENGTH=
}

cgi() {
	export_cgi
	QUERY_STRING=$(echo "$1" | sed 's/^.*\?//')
	PATH_INFO=$(echo "$1" | sed 's/^.*\.cgi.*\?//')
	REQUEST_METHOD="GET"
	SCRIPT_NAME=$(echo "$1" | sed 's/^\(.*.cgi\).*$/\1/')
	sent=true
	"${root}$SCRIPT_NAME"
}
# It's okay to call this routine even after senderr(), see $sent
sendfile() {

    $sent && return 0
	test -d "$1" && return
    exec 3<"$root/$1" || { senderr 500; return 0; }
    local ct=$(file -bi "$root/$1") || { senderr 500; return 0; }
    local sz=$(ls -l "$root/$1" | awk '{print $5}') || { senderr 500; return 0; }
    sent=true
    echo "HTTP/1.1 200 OK\r"
    echo "Content-Type: $ct\r"
    echo "Content-Length: $sz\r"
    echo "Date: $(env LC_ALL=en_US.UTF-8 date)\r"
    echo "\r"
    cat <&3
    exec 3<&-
}

html_escape() {
	echo "$*" | sed -E \
		-e 's/&/\&amp;/g;' \
		-e 's/"/\&quot;/g;' \
		-e "s/'/\&#39;/g;" \
		-e 's/</\&lt;/g;' \
		-e 's/>/\&gt;/g;'
}

uri_escape() {
	echo "$*" | sed -E \
		-e 's/%/%25/g;' \
		-e 's/&/%26/g;' \
		-e 's/\?/%3f/g;' \
		-e 's/ /%20/g;'
}

html_link() {
	escaped=$(html_escape "$1")
	echo -n "<a href=\"$(uri_escape "$escaped")\">$escaped</a>"
}

format_file_size() {

	local sz=$1
	if [ "$sz" -ge $((1024 * 1024 * 1024 * 1024 * 10)) ]; then
		sz="$((sz / (1024 * 1024 * 1024 * 1024) ))</td><td>TB"
	elif [ "$sz" -ge $((1024 * 1024 * 1024 * 10)) ]; then
		sz="$((sz / (1024 * 1024 * 1024) ))</td><td>GB"
	elif [ "$sz" -ge $((1024 * 1024 * 10)) ]; then
		sz="$((sz / (1024 * 1024) ))</td><td>MB"
	elif [ "$sz" -ge $((1024 * 10)) ]; then
		sz="$((sz / 1024))</td><td>KB"
	else
		sz="${sz}</td><td>B"
	fi
	echo "$sz"
}

file_info() {
	local fname="$1" date="$2" size="$3" type="$4"

	case $type in
	block|char|pipe|socket)	return;;
	esac

	echo -n "<tr><td class=\"fi type\">$(html_escape "$type")</td>"
	test "$type" = "dir" && fname="${fname}/"
	echo -n "<td class=\"fi fname\">$(html_link "$fname")</td>"
	echo -n "<td class=\"fi data\">$(html_escape "$date")</td>"
	echo -n "<td class=\"fi size\">$(format_file_size "$size")</td></tr>"
}

index() {

# to be put back instead of if..elif.. below when ksh bug fixed
    if false; then
		case $(echo $mode | cut -c 1) in
		-) type=file;;
		b) type=block;;
		c) type=char;;
		d) type=dir;;
		l) type=link;;
		p) type=pipe;;
		s) type=socket;;
		*) type=unknown;;
		esac
    fi

	body=$(
cat <<EOF
<html>
<head>
	<title>Index of $(html_escape "$1")</title>
	<style type="text/css">
		.fi { padding-left: 0.5em; }
		.size { text-align: right; }
	</style>
</head>
<body>
<h1>Index of $(html_escape "$1")</h1><hr><table>
EOF

	if [ "X${1%/}" != X ]; then
		parent=${1%%*(/)}
		parent=${parent%/*}
		test -n "$parent" || parent=/
		echo "<a href=\"$parent\">../</a><br />"
	fi

	local mode links owner group size mon day time year name
	local type
	ls -lT "$root$1" | tail -n +2 | while read mode links owner group size mon day time year name; do
		  if [ "${mode#-}" != "$mode" ]; then	type=file
		elif [ "${mode#b}" != "$mode" ]; then	type=block
		elif [ "${mode#c}" != "$mode" ]; then	type=char
		elif [ "${mode#d}" != "$mode" ]; then	type=dir
		elif [ "${mode#l}" != "$mode" ]; then	type=link
		elif [ "${mode#p}" != "$mode" ]; then	type=pipe
		elif [ "${mode#s}" != "$mode" ]; then	type=socket
		else                                 	type=unknown
		fi
		file_info "$name" "${year}-${mon}-${day} $time" "$size" "${type}"
	done

	echo "</table><hr></body>"
	echo "</html>"
	)
	sz=$(echo -n "$body" | wc -c)

        echo "HTTP/1.1 200 OK\r"
        echo "Content-Type: text/html\r"
        echo "Content-Length: $sz\r"
        echo "\r"
        echo -n "$body"
}

NC=nc
if $verbose; then
        NC="$NC -v"
fi
NC="$NC -kl $port"

while true; do
        file=
        sent=false
        $NC |&
        $verbose && echo "watiting for new connection on port $port" >&2
        ncpid=$!
        hasAuthTag=false
        hasLogged=false
        while ! $sent && read -p v1 v2 v3; do
            if [ -z "$file" ]; then
                    file=$v2
                    [[ $v1 = GET ]] || senderr 400
                    [[ $v3 = $(echo "HTTP/1.[01]\r") ]] || senderr 400
            elif [[ $v1 == "Authorization:" ]]; then
                isInUsers $v3
                hasAuthTag=true
                if [[ $v2 == "Basic" && $isInFile == true ]]; then
                    hasLogged=true
                fi
            elif [[ $v1 = $(echo "\r") && -z $v2 ]]; then
                    # empty line
                    if [ -n "$file" ]; then
                        
                        if [[ $hasAuthTag == false ]]; then

                            senderr 401
                        else

                            if [[ $hasLogged == true ]]; then

                                $verbose && echo "$file is requested" >&2
                    			validate_and_send "$file"
                            else

                                senderr 401
                            fi
                        fi

                    else

                        senderr 400
                    fi
			file=
			sent=false
            hasAuthTag=false
            hasLogged=false
                # else ignore all headers
            fi
        done >&p
        exec 3>&p && exec 3>&- && kill $ncpid
        wait
done
