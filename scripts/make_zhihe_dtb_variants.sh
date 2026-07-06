#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <base.dtb> <output-dir>" >&2
	exit 1
fi

base_dtb=$1
outdir=$2

if [ ! -f "$base_dtb" ]; then
	echo "Base DTB not found: $base_dtb" >&2
	exit 1
fi

if ! command -v dtc >/dev/null 2>&1; then
	echo "dtc is required but not installed" >&2
	exit 1
fi

mkdir -p "$outdir"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT INT TERM

src_dts="$tmpdir/source.dts"
dtc -I dtb -O dts -o "$src_dts" "$base_dtb"

phandle=$(awk '
	/sim-ctrl-default-state \{/ {
		inblock = 1
		next
	}
	inblock && /phandle = </ {
		if (match($0, /<[^>]+>/)) {
			value = substr($0, RSTART + 1, RLENGTH - 2)
			print value
			exit
		}
	}
	inblock && /^[[:space:]]*};$/ {
		inblock = 0
	}
' "$src_dts")
if [ -z "$phandle" ]; then
	echo "Could not find sim-ctrl-default-state phandle in $base_dtb" >&2
	exit 1
fi

write_variant_dts() {
	mode=$1
	dst=$2
	awk -v mode="$mode" -v phandle="$phandle" '
	BEGIN {
		inblock = 0
		depth = 0
		replaced = 0
	}
	function count_open(line,   tmp) {
		tmp = line
		return gsub(/\{/, "{", tmp)
	}
	function count_close(line,   tmp) {
		tmp = line
		return gsub(/\};/, "};", tmp)
	}
	function emit_block() {
		print "\t\t\tsim-ctrl-default-state {"
		print "\t\t\t\tphandle = <" phandle ">;"
		if (mode == "physical") {
			print ""
			print "\t\t\t\tesim-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio0\", \"gpio3\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tsim-en-pins {"
			print "\t\t\t\t\tpins = \"gpio1\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tsim-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio2\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-high;"
			print "\t\t\t\t};"
		} else if (mode == "esim1") {
			print ""
			print "\t\t\t\tesim1-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio0\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-high;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tesim2-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio3\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tsim-en-pins {"
			print "\t\t\t\t\tpins = \"gpio1\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tsim-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio2\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
		} else if (mode == "esim2") {
			print ""
			print "\t\t\t\tesim1-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio0\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tesim2-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio3\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-high;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tsim-en-pins {"
			print "\t\t\t\t\tpins = \"gpio1\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
			print ""
			print "\t\t\t\tsim-sel-pins {"
			print "\t\t\t\t\tpins = \"gpio2\";"
			print "\t\t\t\t\tfunction = \"gpio\";"
			print "\t\t\t\t\tbias-disable;"
			print "\t\t\t\t\toutput-low;"
			print "\t\t\t\t};"
		}
		print "\t\t\t};"
	}
	/sim-ctrl-default-state \{/ {
		emit_block()
		inblock = 1
		depth = 1
		replaced = 1
		next
	}
	inblock {
		depth += count_open($0)
		depth -= count_close($0)
		if (depth <= 0) {
			inblock = 0
			depth = 0
		}
		next
	}
	!inblock {
		print
	}
	END {
		if (!replaced) {
			exit 2
		}
	}
	' "$src_dts" > "$dst"
}

build_variant() {
	mode=$1
	out_dtb=$2
	tmp_dts="$tmpdir/$mode.dts"
	write_variant_dts "$mode" "$tmp_dts"
	dtc -I dts -O dtb -o "$out_dtb" "$tmp_dts"
}

cp "$base_dtb" "$outdir/msm8916-thwc-ufi001c-physical.dtb"
build_variant esim1 "$outdir/msm8916-thwc-ufi001c-esim1.dtb"
build_variant esim2 "$outdir/msm8916-thwc-ufi001c-esim2.dtb"

echo "Created DTB variants in $outdir"
