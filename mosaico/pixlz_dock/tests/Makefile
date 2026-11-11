# Host tests for the pure C parts of pixlz_dock: `make -C tests`.
CFLAGS ?= -std=c11 -O1 -g -Wall -Wextra -Wpedantic -Werror -fsanitize=address,undefined
test: build/test_app_game build/test_app_menu
	./build/test_app_game
	./build/test_app_menu
build/test_app_game: test_app_game.c ../components/app_game/app_game.c ../components/app_game/include/app_game.h
	@mkdir -p build
	$(CC) $(CFLAGS) test_app_game.c ../components/app_game/app_game.c -lm -o $@
build/test_app_menu: test_app_menu.c ../components/app_menu/app_menu.c ../components/app_menu/include/app_menu.h
	@mkdir -p build
	$(CC) $(CFLAGS) test_app_menu.c ../components/app_menu/app_menu.c -lm -o $@

clean:
	rm -rf build
.PHONY: test clean
