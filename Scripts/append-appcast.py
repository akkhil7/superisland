#!/usr/bin/env python3
"""Insert a new Sparkle <item> at the top of the channel in appcast.xml.

Usage: append-appcast.py APPCAST VERSION BUILD URL ED_SIG LENGTH MIN_OS
"""
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 8:
    sys.exit("usage: append-appcast.py APPCAST VERSION BUILD URL ED_SIG LENGTH MIN_OS")

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

appcast, version, build, url, ed_sig, length, min_os = sys.argv[1:8]
tree = ET.parse(appcast)
channel = tree.getroot().find("channel")

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, f"{{{SPARKLE}}}version").text = build
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = min_os
enclosure = ET.SubElement(item, "enclosure")
enclosure.set("url", url)
enclosure.set("length", length)
enclosure.set("type", "application/octet-stream")
enclosure.set(f"{{{SPARKLE}}}edSignature", ed_sig)

# Newest first.
channel.insert(list(channel).index(channel.find("title")) + 1, item)
tree.write(appcast, xml_declaration=True, encoding="utf-8")
print(f"Inserted appcast item for {version} (build {build})")
