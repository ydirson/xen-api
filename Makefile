.PHONY: all clean install build reinstall uninstall distclean
all: build

NAME=xenops
J=4

clean:
	@rm -f setup.data setup.log setup.bin lib/version.ml
	@rm -rf _build
	@rm -f xenopsd-xc xenopsd-xenlight xenopsd-simulator xenopsd-libvirt
	@rm -f xenopsd-xc.1 xenopsd-xenlight.1 xenopsd-simulator.1 xenopsd-libvirt.1
	@rm -f *.native

-include config.mk

config.mk:
	echo Please re-run configure
	exit 1

setup.bin: setup.ml
	@ocamlopt.opt -o $@ $< || ocamlopt -o $@ $< || ocamlc -o $@ $<
	@rm -f setup.cmx setup.cmi setup.o setup.cmo

setup.data: setup.bin
	@./setup.bin -configure $(ENABLE_XEN) $(ENABLE_XENLIGHT) $(ENABLE_LIBVIRT) $(ENABLE_XENGUESTBIN)

build: setup.data setup.bin version.ml
	@./setup.bin -build -j $(J)
ifeq ($(ENABLE_XENLIGHT),--enable-xenlight)
	ln -s ./xenops_xl_main.native xenopsd-xenlight || true
	./xenopsd-xenlight --help=groff > xenopsd-xenlight.1
endif
ifeq ($(ENABLE_LIBVIRT),--enable-libvirt)
	ln -s ./xenops_libvirt_main.native xenopsd-libvirt || true
	./xenopsd-libvirt --help=groff > xenopsd-libvirt.1
endif
	ln -s ./xenops_simulator_main.native xenopsd-simulator || true
	./xenopsd-simulator --help=groff > xenopsd-simulator.1
	ln -s ./xenops_xc_main.native xenopsd-xc || true
	./xenopsd-xc --help=groff > xenopsd-xc.1

version.ml: VERSION
	echo "let version = \"$(shell cat VERSION)\"" > lib/version.ml

install:
ifeq ($(ENABLE_XENLIGHT),--enable-xenlight)
	install -D ./xenops_xl_main.native $(DESTDIR)/$(SBINDIR)/xenopsd-xenlight
	install -D ./xenopsd-xenlight.1 $(DESTDIR)/$(MANDIR)/man1/xenopsd-xenlight.1
endif
ifeq ($(ENABLE_LIBVIRT),--enable-libvirt)
	install -D ./xenops_libvirt_main.native $(DESTDIR)/$(SBINDIR)/xenopsd-libvirt
	install -D ./xenopsd-libvirt.1 $(DESTDIR)/$(MANDIR)/man1/xenopsd-libvirt.1
endif
	install -D ./xenops_simulator_main.native $(DESTDIR)/$(SBINDIR)/xenopsd-simulator
	install -D ./xenopsd-simulator.1 $(DESTDIR)/$(MANDIR)/man1/xenopsd-simulator.1
	install -D ./xenops_xc_main.native $(DESTDIR)/$(SBINDIR)/xenopsd-xc
	install -D ./xenopsd-xc.1 $(DESTDIR)/$(MANDIR)/man1/xenopsd-xc.1
	install -D ./scripts/vif $(DESTDIR)/$(SCRIPTSDIR)/vif
	install -D ./scripts/block $(DESTDIR)/$(SCRIPTSDIR)/block
	install -D ./scripts/qemu-dm-wrapper $(DESTDIR)/$(LIBEXECDIR)/qemu-dm-wrapper
	install -D ./scripts/qemu-vif-script $(DESTDIR)/$(LIBEXECDIR)/qemu-vif-script
	install -D ./scripts/setup-vif-rules $(DESTDIR)/$(LIBEXECDIR)/setup-vif-rules
	install -D ./scripts/common.py $(DESTDIR)/$(LIBEXECDIR)/common.py
	install -D ./scripts/network.conf $(DESTDIR)/$(ETCDIR)/xcp/network.conf
	DESTDIR=$(DESTDIR) SBINDIR=$(SBINDIR) LIBEXECDIR=$(LIBEXECDIR) SCRIPTSDIR=$(SCRIPTSDIR) ETCDIR=$(ETCDIR) ./scripts/make-custom-xenopsd.conf

reinstall: install
	@ocamlfind remove $(NAME) || true

uninstall:
	@ocamlfind remove $(NAME) || true
	rm -f $(DESTDIR)/$(SBINDIR)/xenopsd-libvirt
	rm -f $(DESTDIR)/$(SBINDIR)/xenopsd-xenlight
	rm -f $(DESTDIR)/$(SBINDIR)/xenopsd-xc
	rm -f $(DESTDIR)/$(SBINDIR)/xenopsd-simulator
	rm -f $(DESTDIR)/$(MANDIR)/man1/xenopsd-libvirt.1
	rm -f $(DESTDIR)/$(MANDIR)/man1/xenopsd-xenlight.1
	rm -f $(DESTDIR)/$(MANDIR)/man1/xenopsd-xc.1
	rm -f $(DESTDIR)/$(MANDIR)/man1/xenopsd-simluator.1
	rm -f $(DESTDIR)/$(ETCDIR)/xenopsd.conf
	rm -f $(DESTDIR)/$(SCRIPTSDIR)/vif
	rm -f $(DESTDIR)/$(SCRIPTSDIR)/block
	rm -f $(DESTDIR)/$(LIBEXECDIR)/qemu-dm-wrapper
	rm -f $(DESTDIR)/$(LIBEXECDIR)/setup-vif-rules
	rm -f $(DESTDIR)/$(ETCDIR)/xcp/network.conf

