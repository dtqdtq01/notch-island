#!/bin/zsh -e
# Xcode 없이 Command Line Tools의 Swift Testing으로 테스트 실행
cd "${0:A:h}/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L "$@"
