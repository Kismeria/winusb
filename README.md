# winusb

write a windows iso to a usb stick from linux. uefi boot only.

```
curl -fsSL https://raw.githubusercontent.com/Kismeria/winusb/main/winusb.sh | sudo bash
```

pick the stick, pick the iso, confirm. done.

- installs missing deps (apt, pacman, dnf, zypper)
- gpt + fat32, copies the iso, splits `install.wim` if it is over 4gb
- erases the whole stick
- legacy bios boot is not supported
