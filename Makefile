# Smiley for the 48K Spectrum.
#
#   make        assemble into build/ (tape image, listing, symbols)
#   make test   run the host-side tests (needs .venv, see README.md)
#   make clean  delete build/

SJASMPLUS ?= sjasmplus
PYTHON    ?= .venv/bin/python

NAME      := smiley
SOURCE    := src/$(NAME).asm
INCLUDES  := src/loader.asm src/screen.scr
BUILD_DIR := build

TAP     := $(BUILD_DIR)/$(NAME).tap
SYMBOLS := $(BUILD_DIR)/$(NAME).sym
LISTING := $(BUILD_DIR)/$(NAME).lst

.DELETE_ON_ERROR:
.PHONY: all test clean

all: $(TAP)

# The SAVETAP lines in the source write the tape. --outprefix is put in front of
# the file names they use.
$(TAP): $(SOURCE) $(INCLUDES) Makefile | $(BUILD_DIR)
	$(SJASMPLUS) --nologo --outprefix=$(BUILD_DIR)/ --lst=$(LISTING) --sym=$(SYMBOLS) $<

$(BUILD_DIR):
	mkdir -p $@

test: all
	$(PYTHON) -m unittest discover -s tests -v

clean:
	rm -rf $(BUILD_DIR)
