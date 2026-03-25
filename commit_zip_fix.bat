@echo off
git add .
git commit -m "Fix iOS build: Revert to using libndi_ios.zip from release since .a isn't available"
git push
