# Host tests for the trip module: `make test`. Fixtures come from PixlzCore:
#   (cd ../tools/PixlzSend && swift run PixlzSend fixtures ../../pixl_trip/test/fixtures)
CFLAGS ?= -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -fsanitize=address,undefined -fno-omit-frame-pointer
SRC = src/pt_sha256.c src/pt_crypto.c src/pt_pair.c src/pt_adpcm.c src/pt_frame.c src/pt_json.c src/pt_trip.c

build/test_pixl_trip: $(SRC) test/test_pixl_trip.c $(wildcard include/pixl_trip/*.h)
	@mkdir -p build
	$(CC) $(CFLAGS) -Iinclude $(SRC) test/test_pixl_trip.c -o $@

test: build/test_pixl_trip
	./build/test_pixl_trip test/fixtures

clean:
	rm -rf build

.PHONY: test clean
