BIN      := soundferret
SRC      := soundferret.swift
MIN_OS   := 14.2
SWIFTC   ?= swiftc
SWIFTFLAGS := -O -framework CoreAudio -framework Foundation

.PHONY: all check clean

all: check $(BIN)

check:
	@uname -s | grep -q Darwin || { echo "error: macOS only (uname=$$(uname -s))"; exit 1; }
	@osver=$$(sw_vers -productVersion); \
	  awk -v v="$$osver" -v m="$(MIN_OS)" 'BEGIN{ \
	    split(v,a,"."); split(m,b,"."); \
	    for(i=1;i<=2;i++){ ai=a[i]+0; bi=b[i]+0; \
	      if(ai>bi)exit 0; if(ai<bi)exit 1; } exit 0 }' \
	  || { echo "error: need macOS $(MIN_OS)+, have $$osver"; exit 1; }
	@command -v $(SWIFTC) >/dev/null 2>&1 \
	  || { echo "error: $(SWIFTC) not found (install Xcode CLT: xcode-select --install)"; exit 1; }

$(BIN): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $<

clean:
	rm -f $(BIN)
