# Makefile - one-command simulation with Icarus Verilog (iverilog + vvp).
#   make test       self-checking tests (output-stationary V1, weight-stationary W1 and W3)
#   make demo       the blind-spot demos: plain checker misses, doubling checker detects
#   make campaign   one full fault campaign (default: W3; e.g. make campaign V=v1d)
#   make clean

IV  = iverilog -g2005
OUT = build
V  ?= w3

OS  = rtl/pe.v rtl/systolic_array.v rtl/skew_line.v rtl/array_top.v rtl/sum_tree.v
OSD = rtl/pe_d.v rtl/systolic_array_d.v rtl/skew_line.v rtl/array_top_d.v rtl/sum_tree.v
WS  = rtl/pe_ws.v rtl/systolic_array_ws.v rtl/skew_line.v rtl/ws_top.v rtl/sum_tree.v \
      rtl/labft_checker_ws.v rtl/labft_checker_ws_w.v rtl/labft_top_ws.v rtl/labft_top_ws3.v

.PHONY: test demo campaign clean

$(OUT):
	mkdir -p $(OUT)

test: | $(OUT)
	@echo "== V1: output-stationary + Light ABFT, 20 random 4x4 multiplications"
	$(IV) -o $(OUT)/v1.vvp tb/tb_standalone.v $(OS) rtl/labft_checker.v rtl/labft_top.v
	vvp -n $(OUT)/v1.vvp | grep RESULT | grep -q PASS
	@echo "== W1: weight-stationary + Light ABFT"
	$(IV) -o $(OUT)/w1.vvp tb/tb_ws_standalone.v $(WS)
	vvp -n $(OUT)/w1.vvp | grep RESULT | grep -q PASS
	@echo "== W3: weight-stationary + doubling checker"
	$(IV) -DW3 -o $(OUT)/w3.vvp tb/tb_ws_standalone.v $(WS)
	vvp -n $(OUT)/w3.vvp | grep RESULT | grep -q PASS
	@echo "All tests passed."

demo: | $(OUT)
	@echo "== Row-by-row readout, plain checker (expect alarm = 0: missed)"
	$(IV) -DDRAIN -o $(OUT)/d.vvp tb/tb_drain_cancel_demo.v $(OSD) rtl/labft_checker_d.v rtl/labft_top_d.v
	vvp -n $(OUT)/d.vvp | grep -v finish
	@echo "== Row-by-row readout, doubling checker (expect alarm = 1: detected)"
	$(IV) -DDW -o $(OUT)/dw.vvp tb/tb_drain_cancel_demo.v $(OSD) rtl/labft_checker_dw.v rtl/labft_top_dw.v
	vvp -n $(OUT)/dw.vvp | grep -v finish
	@echo "== Weight-stationary, plain checker (expect alarm = 0: missed)"
	$(IV) -o $(OUT)/wd.vvp tb/tb_ws_cancel_demo.v $(WS)
	vvp -n $(OUT)/wd.vvp | grep -v finish
	@echo "== Weight-stationary, doubling checker (expect alarm = 1: detected)"
	$(IV) -DW3 -o $(OUT)/wd3.vvp tb/tb_ws_cancel_demo.v $(WS)
	vvp -n $(OUT)/wd3.vvp | grep -v finish

campaign:
	python3 fi/campaign.py --variant $(V) --n 4 --k 4 --kind persistent

clean:
	rm -rf $(OUT) results sim fi/sites fi/__pycache__ scripts/__pycache__
