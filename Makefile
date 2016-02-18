REBAR ?= "$(CURDIR)/rebar"
PREFIX ?= /usr/local
DOCS := master
ELIXIRC := bin/elixirc --verbose --ignore-module-conflict
ERLC := erlc -I lib/elixir/include
ERL := erl -I lib/elixir/include -noshell -pa lib/elixir/ebin
VERSION := $(strip $(shell cat VERSION))
Q := @
LIBDIR := lib
INSTALL = install
INSTALL_DIR = $(INSTALL) -m755 -d
INSTALL_DATA = $(INSTALL) -m644
INSTALL_PROGRAM = $(INSTALL) -m755
GIT_REVISION = $(strip $(shell git rev-parse HEAD 2> /dev/null ))
GIT_TAG = $(strip $(shell head="$(call GIT_REVISION)"; git tag --points-at $$head 2> /dev/null | tail -1) )

.PHONY: install compile erlang elixir build_plt clean_plt dialyze test clean install_man clean_man docs Docs.zip Precompiled.zip publish_zips publish_docs publish_mix
.NOTPARALLEL: compile

#==> Functions

define CHECK_ERLANG_RELEASE
	$(Q) erl -noshell -eval 'io:fwrite("~s", [erlang:system_info(otp_release) >= "18"])' -s erlang halt | grep -q '^true'; \
		if [ $$? != 0 ]; then \
		   echo "At least Erlang 18.0 is required to build Elixir"; \
		   exit 1; \
		fi;
endef

define APP_TEMPLATE
$(1): lib/$(1)/ebin/Elixir.$(2).beam lib/$(1)/ebin/$(1).app

lib/$(1)/ebin/$(1).app: lib/$(1)/mix.exs
	$(Q) mkdir -p lib/$(1)/_build/shared/lib/$(1)
	$(Q) cp -R lib/$(1)/ebin lib/$(1)/_build/shared/lib/$(1)/
	$(Q) cd lib/$(1) && ../../bin/elixir -e 'Mix.start(:permanent, [])' -r mix.exs -e 'Mix.Task.run("compile.app")'
	$(Q) cp lib/$(1)/_build/shared/lib/$(1)/ebin/$(1).app lib/$(1)/ebin/$(1).app
	$(Q) rm -rf lib/$(1)/_build

lib/$(1)/ebin/Elixir.$(2).beam: $(wildcard lib/$(1)/lib/*.ex) $(wildcard lib/$(1)/lib/*/*.ex) $(wildcard lib/$(1)/lib/*/*/*.ex)
	@ echo "==> $(1) (compile)"
	@ rm -rf lib/$(1)/ebin
	$(Q) cd lib/$(1) && ../../$$(ELIXIRC) "lib/**/*.ex" -o ebin

test_$(1): compile $(1)
	@ echo "==> $(1) (exunit)"
	$(Q) cd lib/$(1) && ../../bin/elixir -r "test/test_helper.exs" -pr "test/**/*_test.exs";
endef

#==> Compilation tasks

KERNEL:=lib/elixir/ebin/Elixir.Kernel.beam
UNICODE:=lib/elixir/ebin/Elixir.String.Unicode.beam

default: compile

compile: lib/elixir/src/elixir.app.src erlang elixir

lib/elixir/src/elixir.app.src: src/elixir.app.src
	$(Q) $(call CHECK_ERLANG_RELEASE)
	$(Q) rm -rf lib/elixir/src/elixir.app.src
	$(Q) echo "%% This file is automatically generated from <project_root>/src/elixir.app.src" \
	                             >lib/elixir/src/elixir.app.src
	$(Q) cat src/elixir.app.src >>lib/elixir/src/elixir.app.src

erlang:
	$(Q) cd lib/elixir && $(REBAR) compile

# Since Mix depends on EEx and EEx depends on
# Mix, we first compile EEx without the .app
# file, then mix and then compile EEx fully
elixir: stdlib lib/eex/ebin/Elixir.EEx.beam mix ex_unit logger eex iex

stdlib: $(KERNEL) VERSION
$(KERNEL): lib/elixir/lib/*.ex lib/elixir/lib/*/*.ex lib/elixir/lib/*/*/*.ex
	$(Q) if [ ! -f $(KERNEL) ]; then                  \
		echo "==> bootstrap (compile)";                 \
		$(ERL) -s elixir_compiler core -s erlang halt;  \
	fi
	@ echo "==> elixir (compile)";
	$(Q) cd lib/elixir && ../../$(ELIXIRC) "lib/kernel.ex" -o ebin;
	$(Q) cd lib/elixir && ../../$(ELIXIRC) "lib/**/*.ex" -o ebin;
	$(Q) $(MAKE) unicode
	$(Q) rm -rf lib/elixir/ebin/elixir.app
	$(Q) cd lib/elixir && $(REBAR) compile

unicode: $(UNICODE)
$(UNICODE): lib/elixir/unicode/*
	@ echo "==> unicode (compile)";
	@ echo "Embedding the Unicode database... (this may take a while)"
	$(Q) cd lib/elixir && ../../$(ELIXIRC) unicode/unicode.ex -o ebin;

$(eval $(call APP_TEMPLATE,ex_unit,ExUnit))
$(eval $(call APP_TEMPLATE,logger,Logger))
$(eval $(call APP_TEMPLATE,eex,EEx))
$(eval $(call APP_TEMPLATE,mix,Mix))
$(eval $(call APP_TEMPLATE,iex,IEx))

install: compile
	@ echo "==> elixir (install)"
	$(Q) for dir in lib/*; do \
		rm -Rf $(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/$$dir/ebin; \
		$(INSTALL_DIR) "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/$$dir/ebin"; \
		$(INSTALL_DATA) $$dir/ebin/* "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/$$dir/ebin"; \
	done
	$(Q) $(INSTALL_DIR) "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/bin"
	$(Q) $(INSTALL_PROGRAM) $(filter-out %.ps1, $(filter-out %.bat, $(wildcard bin/*))) "$(DESTDIR)$(PREFIX)/$(LIBDIR)/elixir/bin"
	$(Q) $(INSTALL_DIR) "$(DESTDIR)$(PREFIX)/bin"
	$(Q) for file in "$(DESTDIR)$(PREFIX)"/$(LIBDIR)/elixir/bin/* ; do \
		ln -sf "../$(LIBDIR)/elixir/bin/$${file##*/}" "$(DESTDIR)$(PREFIX)/bin/" ; \
	done
	$(MAKE) install_man

clean:
	cd lib/elixir && $(REBAR) clean
	rm -rf ebin
	rm -rf lib/*/ebin
	rm -rf lib/elixir/test/ebin
	rm -rf lib/*/tmp
	rm -rf lib/mix/test/fixtures/git_repo
	rm -rf lib/mix/test/fixtures/deps_on_git_repo
	rm -rf lib/mix/test/fixtures/git_rebar
	rm -rf lib/elixir/src/elixir.app.src
	$(MAKE) clean_man

clean_exbeam:
	$(Q) rm -f lib/*/ebin/Elixir.*.beam

#==> Create Documentation

LOGO_PATH = $(shell test -f ../docs/logo.png && echo "--logo ../docs/logo.png")
SOURCE_REF = $(shell tag="$(call GIT_TAG)" revision="$(call GIT_REVISION)"; echo "$${tag:-$$revision}\c")
COMPILE_DOCS = bin/elixir ../ex_doc/bin/ex_doc "$(1)" "$(VERSION)" "lib/$(2)/ebin" -m "$(3)" -u "https://github.com/elixir-lang/elixir" --source-ref "$(call SOURCE_REF)" $(call LOGO_PATH) -o doc/$(2) -p http://elixir-lang.org/docs.html $(4)

docs: compile ../ex_doc/bin/ex_doc docs_elixir docs_eex docs_mix docs_iex docs_ex_unit docs_logger

docs_elixir: compile ../ex_doc/bin/ex_doc
	@ echo "==> ex_doc (elixir)"
	$(Q) rm -rf doc/elixir
	$(call COMPILE_DOCS,Elixir,elixir,Kernel,-e "lib/elixir/pages/Naming Conventions.md" -e "lib/elixir/pages/Typespecs.md" -e "lib/elixir/pages/Writing Documentation.md")

docs_eex: compile ../ex_doc/bin/ex_doc
	@ echo "==> ex_doc (eex)"
	$(Q) rm -rf doc/eex
	$(call COMPILE_DOCS,EEx,eex,EEx)

docs_mix: compile ../ex_doc/bin/ex_doc
	@ echo "==> ex_doc (mix)"
	$(Q) rm -rf doc/mix
	$(call COMPILE_DOCS,Mix,mix,Mix)

docs_iex: compile ../ex_doc/bin/ex_doc
	@ echo "==> ex_doc (iex)"
	$(Q) rm -rf doc/iex
	$(call COMPILE_DOCS,IEx,iex,IEx)

docs_ex_unit: compile ../ex_doc/bin/ex_doc
	@ echo "==> ex_doc (ex_unit)"
	$(Q) rm -rf doc/ex_unit
	$(call COMPILE_DOCS,ExUnit,ex_unit,ExUnit)

docs_logger: compile ../ex_doc/bin/ex_doc
	@ echo "==> ex_doc (logger)"
	$(Q) rm -rf doc/logger
	$(call COMPILE_DOCS,Logger,logger,Logger)

../ex_doc/bin/ex_doc:
	@ echo "ex_doc is not found in ../ex_doc as expected. See README for more information."
	@ false

#==> Zips

Docs.zip: docs
	rm -rf Docs-v$(VERSION).zip
	zip -9 -r Docs-v$(VERSION).zip CHANGELOG.md doc NOTICE LICENSE README.md
	@ echo "Docs file created $(CURDIR)/Docs-v$(VERSION).zip"

Precompiled.zip: build_man compile
	rm -rf Precompiled-v$(VERSION).zip
	zip -9 -r Precompiled-v$(VERSION).zip bin CHANGELOG.md lib/*/ebin LICENSE man NOTICE README.md VERSION
	@ echo "Precompiled file created $(CURDIR)/Precompiled-v$(VERSION).zip"

#==> Publish

publish_zips: Precompiled.zip Docs.zip

publish_docs: docs
	rm -rf ../docs/$(DOCS)/*/
	cp -R doc/* ../docs/$(DOCS)

#==> Tests tasks

test: test_erlang test_elixir

TEST_ERL = lib/elixir/test/erlang
TEST_EBIN = lib/elixir/test/ebin
TEST_ERLS = $(addprefix $(TEST_EBIN)/, $(addsuffix .beam, $(basename $(notdir $(wildcard $(TEST_ERL)/*.erl)))))

test_erlang: compile $(TEST_ERLS)
	@ echo "==> elixir (eunit)"
	$(Q) $(ERL) -pa $(TEST_EBIN) -s test_helper test;
	@ echo ""

$(TEST_EBIN)/%.beam: $(TEST_ERL)/%.erl
	$(Q) mkdir -p $(TEST_EBIN)
	$(Q) $(ERLC) -o $(TEST_EBIN) $<

test_elixir: test_stdlib test_ex_unit test_logger test_mix test_eex test_iex

test_stdlib: compile
	@ echo "==> elixir (exunit)"
	$(Q) exec epmd & exit
	$(Q) if [ "$(OS)" = "Windows_NT" ]; then \
		cd lib/elixir && cmd //C call ../../bin/elixir.bat -r "test/elixir/test_helper.exs" -pr "test/elixir/**/*_test.exs"; \
	else \
		cd lib/elixir && ../../bin/elixir -r "test/elixir/test_helper.exs" -pr "test/elixir/**/*_test.exs"; \
	fi

#==> Dialyzer tasks

DIALYZER_OPTS = --no_check_plt --fullpath -Werror_handling -Wunmatched_returns -Wunderspecs
PLT = .elixir.plt

$(PLT):
	@ echo "==> Building PLT with Elixir's dependencies..."
	$(Q) dialyzer --output_plt $(PLT) --build_plt --apps erts kernel stdlib compiler syntax_tools parsetools tools ssl inets

clean_plt:
	$(Q) rm -f $(PLT)

build_plt: clean_plt $(PLT)

dialyze: compile $(PLT)
	@ echo "==> Dialyzing Elixir..."
	$(Q) dialyzer --plt $(PLT) $(DIALYZER_OPTS) lib/*/ebin

#==> Man page tasks

build_man: man/iex.1 man/elixir.1

man/iex.1:
	$(Q) cp man/iex.1.in man/iex.1
	$(Q) sed -i.bak "/{COMMON}/r common" man/iex.1
	$(Q) sed -i.bak "/{COMMON}/d" man/iex.1
	$(Q) rm man/iex.1.bak

man/elixir.1:
	$(Q) cp man/elixir.1.in man/elixir.1
	$(Q) sed -i.bak "/{COMMON}/r common" man/elixir.1
	$(Q) sed -i.bak "/{COMMON}/d" man/elixir.1
	$(Q) rm man/elixir.1.bak

clean_man:
	rm -f man/elixir.1
	rm -f man/iex.1

install_man: build_man
	$(Q) mkdir -p $(DESTDIR)$(PREFIX)/share/man/man1
	$(Q) $(INSTALL_DATA) man/elixir.1  $(DESTDIR)$(PREFIX)/share/man/man1
	$(Q) $(INSTALL_DATA) man/elixirc.1 $(DESTDIR)$(PREFIX)/share/man/man1
	$(Q) $(INSTALL_DATA) man/iex.1     $(DESTDIR)$(PREFIX)/share/man/man1
	$(Q) $(INSTALL_DATA) man/mix.1     $(DESTDIR)$(PREFIX)/share/man/man1
	$(MAKE) clean_man
