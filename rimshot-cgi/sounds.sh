#!/bin/bash

# The rimshot CGI script - Trolling HSBXL with style
# (c) 2012 Frederic Pasteleurs <askarel@gmail.com>
#
# CSS and minor improvements by ZipionLive
# Space-in-filename bug fix by Tom Behets
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program or from the site that you downloaded it
# from; if not, write to the Free Software Foundation, Inc., 59 Temple
# Place, Suite 330, Boston, MA  02111-1307   USA
#

DIR_AUDIOFILES="/srv/sharedfolder/trolling_page"
PAGETITLE="Rimshot and other shit"
#DIR_AUDIOFILES="./filez"
ME=$(basename $0)
CSSDIR="$DIR_AUDIOFILES/.CSS"
TEMPLATE="$CSSDIR/$ME-template.html"
# buttons definition
SPEECHBAR="Speech synth: <INPUT TYPE=\"text\"  NAME=\"SPEAK\" ID=\"SPEAK\" onkeydown=\"if (event.keyCode == 13 ) {troll ('SPEAK=' + document.getElementById('SPEAK').value); return false; }\" />"
HTMLTROLLBUTTON='<BUTTON TYPE="BUTTON" VALUE="Submit" ID="%s" NAME="%s" CLASS="%s soundBtn" ONCLICK="troll('\''%s'\'')">%s</BUTTON>\n'
# HTMLSIDEBAR='<A HREF="#%s">%s</A> <br />\n'
#internals
CSSMETHOD="CSS"
JSONMETHOD="JSON"
POSTSPEAKMETHOD="SPEAK"
POSTRANDOMMETHOD="RANDOM"
PLAYPROG="paplay"
SPEECHMETHOD="flitemethod"
#DEBUG=blaah

# Speech method: using flite
flitemethod()
{
    SPEECHBIN="$(which flite)"
    if [ $? = 0 ]; then # Installed ? Something to say ?
	test -n "$1" && $SPEECHBIN -t "$1" 
    else # Selected speech method unavailable ? Remove menu item.
	unset SPEECHBAR
    fi
}

# Dump error message specified by parameter 1
htmlbombmsg()
{
cat << BOMB
<!DOCTYPE html>
<HTML>
 <HEAD>
  <TITLE>$PAGETITLE</TITLE>
 </HEAD>
 <BODY>
    <H1>$1</H1><BR />Troll another day...
 </BODY>
</HTML>
BOMB
}

# Error 404: file specified as parameter 1 not found
err404()
{
printf 'Status: 404 not found\nContent-Type: text/html\n\n'
htmlbombmsg "404 FILE \"$(basename "$1")\" NOT FOUND"
}

# Pick a file from specified directory
# Secure handling of user-defined input: avoid the abuse of the '../' trick.
# Return a full path to a file if a match is found in directory.
# Return nothing if file not found/directory empty
# parameter 1: target directory
# parameter 2: requested file
pickfile()
{
    ls -1 "$1" | while read line; do
    test "$line" = "$2" && echo "$1/$line"
    done
}

# Pick a file using the filename hash
# Return full path to the file if in database.
# Return nothing if there is no match
# parameter 1: requested file hash
# THIS FUNCTION IS EXPOSED TO USER INPUT
pickfilehash()
{
    find "$DIR_AUDIFILES" -xtype f \( -iname "*" ! -iname ".*" \) -not -path "*/.*"  -exec /bin/sh -c \
	'printf "%s %s\n" "$(echo -n "{}" | md5sum | cut -d " " -f 1 )" "{}"' \; | while read trollhash trollfile; do 
	    test "$trollhash" = "$1" && echo "$trollfile"
	 done
#    echo "$FILEHASHDB"|grep "$1" | cut -d ' ' -f 2-
}

# Spit out the HTML code for a button
# Parameter 1: full path to file
printhtmlbuttonhash()
{
    local btnhash="$(echo -n "$1" | md5sum | cut -d ' ' -f 1 )"
    printf "    $HTMLTROLLBUTTON" "$btnhash" "$btnhash" "$btnhash" "$btnhash" "$(basename "$1")"
}

# Make a section with anchor for a category
# Parameter 1: path to generate buttons for
printhtmlsectionhash()
{
    local ITEMNAME="${1#$DIR_AUDIOFILES}"
    test -n "$ITEMNAME" && printf '<DIV ID="%s"><H2>%s</H2></DIV>\n' "$(echo -n "$1" | md5sum | cut -d " " -f 1 )" "$ITEMNAME"
    find "$1" -maxdepth 1 -xtype f \( -iname "*" ! -iname ".*" \) -not -path "*/.*" |while read btn; do printhtmlbuttonhash "$btn"; done
}

# Show the page.
showpagehash()
{
if [ -f "$TEMPLATE" ]; then
    if [ -d "$DIR_AUDIOFILES" ]; then
	# Sidebar 
	SIDEBAR="$(find "$DIR_AUDIOFILES" -xtype d \( -iname "*" ! -iname ".*" ! -wholename "$DIR_AUDIOFILES" \) -not -path "*/.*"  -exec /bin/sh -c \
	    'printf "<A HREF=\"#%s\">%s</A> <br />\n" "$(echo -n "{}" | md5sum | cut -d " " -f 1 )" "$(basename "{}")"' \;)"
	# Make categories
	TROLLBODY="$(find "$DIR_AUDIOFILES" -xtype d \( -iname "*" ! -iname ".*" \) -not -path "*/.*" | while read line; do printhtmlsectionhash "$line"; done)"
    fi
    # Prime the template variables and show the page
    export PAGETITLE ME TROLLBODY SIDEBAR SPEECHBAR FOOTER
    cat $TEMPLATE | envsubst
else # Template not found. Complain loudly.
    htmlbombmsg "MISSING TEMPLATE: $TEMPLATE"
fi
}

# Valid speech method ?
test -n "$SPEECHMETHOD" && $SPEECHMETHOD

case "$( echo "$QUERY_STRING"|cut -d '=' -f 1 )" in
    "$CSSMETHOD")
	CSSFILE="$( echo "$QUERY_STRING"|cut -d '=' -f 2 )"
	if [ -n "$( pickfile "$CSSDIR" "$CSSFILE" )" ]; then
	    printf "Content-type: text/css\n\n"
	    cat "$( pickfile "$CSSDIR" "$CSSFILE" )"
	else
	    err404 "$CSSFILE"
	fi
	;;
    "$JSONMETHOD") # Dump a JSON version of the page. Must be rebuilt nearly from scratch.
	printf 'Content-type: application/json\n\n'
	printf '{\n	"Title:": "%s"' "$PAGETITLE"
	if [ -d "$DIR_AUDIOFILES" ]; then
	    # Create the hash database. Ignores any file/directory beginning with a dot.
	    FILEHASHDB="$(find "$DIR_AUDIOFILES" -xtype f \( -iname "*" ! -iname ".*" \) -exec /bin/sh -c 'printf "%s %s\n" "`echo -n \"{}\"|md5sum| cut -d  \" \" -f 1`" "{}" ' \;)"
	    DIRHASHDB="$(find "$DIR_AUDIOFILES" -xtype d \( -iname "*" ! -iname ".*" \) -exec /bin/sh -c 'printf "%s %s\n" "`echo -n \"{}\"|md5sum| cut -d  \" \" -f 1`" "{}" ' \;)"
	    printf ',\n		"buttons": {\n		"RANDOM": "RANDOM"'
	    echo "$DIRHASHDB"| while read directoryhash directoryname; do 
		test "$directoryname" != "$DIR_AUDIOFILES" && jdirectoryname="$(basename "$directoryname")"
		printf ',\n		"%s": {\n			"directoryname": "%s"' "$directoryhash" "$jdirectoryname"
		echo "$FILEHASHDB" | while read filehash filename; do # Make buttons
		    test "$(dirname "$filename")" = "$directoryname" && 
			printf ',\n			"%s": "%s"' "$filehash" "$(basename "$filename")" 
		done
		printf '\n			}'
	    done
	    printf '\n		}'
	fi
	printf "\n}\n"
	;;
    *) # Catch-all method. Data is in the POST
	# Process POSTed data
	printf 'Content-type: text/html\n\n'
	if [ "$REQUEST_METHOD" = "POST" -a -n "$CONTENT_LENGTH" ]; then
	    read -n "$CONTENT_LENGTH" POSTDATA
	    test -n "$DEBUG" && logger -t $ME-post "POST data: '$POSTDATA'"
	    if [ -n "$POSTDATA" -a "$POSTDATA" != "[object HTMLFormElement]" ]; then # Is there something in the POSTed data ?
		POSTDATAVAR="$(echo -n "$POSTDATA"|cut -d '=' -f 1)"
		case "$POSTDATAVAR" in
		    "$POSTRANDOMMETHOD")# Random button (roll the dice)
			$PLAYPROG "$(pickfilehash "$( find "$DIR_AUDIOFILES" -xtype f \( -iname "*" ! -iname ".*" \) -not -path "*/.*"  -exec /bin/sh -c 'echo -n "{}" | md5sum | cut -d " " -f 1  ' \; |shuf -n 1)")" & #" choke alert
		        ;;
		    "$POSTSPEAKMETHOD") # Speech synth method.
			SPEECHTEXT="$(echo "$POSTDATA" | cut -d '=' -f 2-)"
			test -n "$SPEECHMETHOD" && $SPEECHMETHOD "$SPEECHTEXT"
			;;
		    *)# The rest...
		        test -n "$( pickfilehash "$POSTDATAVAR" )" && $PLAYPROG "$( pickfilehash "$POSTDATAVAR")"
			;;
		esac
	    fi
	else
	    showpagehash
	fi
	;;
esac
