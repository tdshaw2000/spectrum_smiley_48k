# Smiley for the 48K Spectrum.
#
#   make        assemble into build/ (tape images, listing, symbols)
#   make test   run the host-side tests (needs .venv, see README.md)
#   make clean  delete build/

PASMO  ?= pasmo
PYTHON ?= .venv/bin/python

NAME      := smiley
SOURCE    := src/$(NAME).asm
BUILD_DIR := build

TAP     := $(BUILD_DIR)/$(NAME).tap
TZX     := $(BUILD_DIR)/$(NAME).tzx
BINARY  := $(BUILD_DIR)/$(NAME).bin
SYMBOLS := $(BUILD_DIR)/$(NAME).sym
LISTING := $(BUILD_DIR)/$(NAME).lst

.DELETE_ON_ERROR:
.PHONY: all test clean

all: $(TAP) $(TZX) $(LISTING)

# --tapbas / --tzxbas put a BASIC loader in front of the code block.
# --name sets the name in the code block's tape header.
$(TAP): $(SOURCE) | $(BUILD_DIR)
	$(PASMO) --name $(NAME) --tapbas $< $@ $(SYMBOLS)

$(TZX): $(SOURCE) | $(BUILD_DIR)
	$(PASMO) --name $(NAME) --tzxbas $< $@

# pasmo has no listing option; -d prints each address, opcode and instruction.
$(LISTING): $(SOURCE) | $(BUILD_DIR)
	$(PASMO) -d $< $(BINARY) > $@

$(BUILD_DIR):
	mkdir -p $@

test: all
	$(PYTHON) -m unittest discover -s tests -v

clean:
	rm -rf $(BUILD_DIR)
