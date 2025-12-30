`timescale 1ns/1ps

module reg_ctrl (
  input  logic        clk,
  input  logic        rstn,
  input  logic [7:0]  addr,
  input  logic        sel,
  input  logic        wr,
  input  logic        acc,
  input  logic        func,
  input  logic [23:0] wdata,
  output logic [23:0] rdata,
  output logic        ready
);

  logic [23:0] mem [0:255];

  integer i;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      for (i = 0; i < 256; i = i + 1)
        mem[i] <= 24'h001234;

      rdata <= 24'h001234;
      ready <= 1'b1;
    end
    else begin
      ready <= sel;

      if (sel) begin
        if (wr) begin
          if (!acc)
            mem[addr] <= wdata;
          else if (!func)
            mem[addr] <= mem[addr] + wdata;
          else
            mem[addr] <= mem[addr] * wdata;
        end
        else begin
          rdata <= mem[addr];
        end
      end
    end
  end
endmodule

interface reg_if #(
  parameter int ADDR_WIDTH = 8,
  parameter int DATA_WIDTH = 24
)(
  input logic clk
);
  logic rstn;
  logic [ADDR_WIDTH-1:0] addr;
  logic sel;
  logic wr;
  logic acc;
  logic func;
  logic [DATA_WIDTH-1:0] wdata;
  logic [DATA_WIDTH-1:0] rdata;
  logic ready;

  clocking cb @(posedge clk);
    default input #1step output #1step;
    output rstn, addr, sel, wr, acc, func, wdata;
    input  rdata, ready;
  endclocking
endinterface


module tb;

  localparam int ADDR_WIDTH = 8;
  localparam int DATA_WIDTH = 24;
  localparam logic [DATA_WIDTH-1:0] RESET_VAL = 24'h001234;

  logic clk = 0;
  always #5 clk = ~clk;

  reg_if #(ADDR_WIDTH, DATA_WIDTH) ifc(clk);

  reg_ctrl dut (
    .clk   (clk),
    .rstn  (ifc.rstn),
    .addr  (ifc.addr),
    .sel   (ifc.sel),
    .wr    (ifc.wr),
    .acc   (ifc.acc),
    .func  (ifc.func),
    .wdata (ifc.wdata),
    .rdata (ifc.rdata),
    .ready (ifc.ready)
  );


  class Transaction;
    rand logic [ADDR_WIDTH-1:0] addr;
    rand bit wr;
    rand bit acc;
    rand bit func;
    rand logic [DATA_WIDTH-1:0] wdata;

    logic [DATA_WIDTH-1:0] rdata;
    bit ready;

    constraint c_addr {
      addr dist {
        8'h00 := 3, 8'h01 := 3, 8'hFE := 3, 8'hFF := 3,
        8'h55 := 3, 8'hAA := 3,
        8'h7E := 2, 8'h7F := 2, 8'h80 := 2, 8'h81 := 2,
        8'h01 := 2, 8'h02 := 2, 8'h04 := 2, 8'h08 := 2,
        8'h10 := 2, 8'h20 := 2, 8'h40 := 2, 8'h80 := 2,
        [0:255] := 1
      };
    }

    constraint c_wdata {
      wdata dist {
        24'h000000 := 2,
        24'hFFFFFF := 2,
        24'h555555 := 2,
        24'hAAAAAA := 2,
        24'h0000FF := 3,
        24'h00FF00 := 3,
        24'hFF0000 := 3,
        [0:(1<<24)-1] := 1
      };
    }
  endclass

  covergroup CovCode @(ifc.cb);
    option.per_instance = 1;

    addr_cp : coverpoint ifc.addr {
      bins boundary[] = {0,1,254,255};
      bins onehot[]   = {1,2,4,8,16,32,64,128};
      bins alt[]      = {8'h55,8'hAA};
      bins middle[]   = {8'h7E,8'h7F,8'h80,8'h81};
    }

    wr_cp   : coverpoint ifc.wr;
    acc_cp  : coverpoint ifc.acc;
    func_cp : coverpoint ifc.func;

    wdata_cp : coverpoint ifc.wdata iff (ifc.wr) {
      bins zero  = {24'h000000};
      bins ones  = {24'hFFFFFF};
      bins byte0 = {24'h0000FF};
      bins byte1 = {24'h00FF00};
      bins byte2 = {24'hFF0000};
    }

    rdata_cp : coverpoint ifc.rdata iff (!ifc.wr);

    cross_all : cross addr_cp, wr_cp, acc_cp, func_cp;
  endgroup

  CovCode ck;

  logic [DATA_WIDTH-1:0] model_mem [0:255];

  task init_model();
    for (int i = 0; i < 256; i++)
      model_mem[i] = RESET_VAL;
  endtask

  task check(Transaction tr);
    if (tr.ready !== 1'b1)
      $error("READY ERROR at time %0t", $time);

    if (!tr.wr) begin
      if (tr.rdata !== model_mem[tr.addr]) begin
        $error("READ ERROR addr=%0h exp=%0h got=%0h",
               tr.addr, model_mem[tr.addr], tr.rdata);
      end
    end
    else begin
      if (!tr.acc)
        model_mem[tr.addr] = tr.wdata;
      else if (!tr.func)
        model_mem[tr.addr] =
          (model_mem[tr.addr] + tr.wdata) & ((1<<DATA_WIDTH)-1);
      else
        model_mem[tr.addr] =
          (model_mem[tr.addr] * tr.wdata) & ((1<<DATA_WIDTH)-1);
    end
  endtask


  task drive(Transaction tr);
    ifc.cb.addr  <= tr.addr;
    ifc.cb.wr    <= tr.wr;
    ifc.cb.acc   <= tr.acc;
    ifc.cb.func  <= tr.func;
    ifc.cb.wdata <= tr.wdata;
    ifc.cb.sel   <= 1;

    @(ifc.cb);
    ifc.cb.sel <= 0;

    repeat (200) begin
      @(ifc.cb);
      if (ifc.ready) break;
    end

    tr.ready = ifc.ready;
    tr.rdata = ifc.rdata;

    check(tr);
  endtask



  initial begin
    Transaction tr;

    ck = new();
    init_model();

    // reset
    ifc.cb.rstn <= 0;
    ifc.cb.sel  <= 0;
    repeat (5) @(ifc.cb);
    ifc.cb.rstn <= 1;

    // Phase 1: reads after reset
    repeat (2000) begin
      tr = new();
      assert(tr.randomize() with { wr == 0; });
      drive(tr);
    end

    // Phase 2: full random
    repeat (20000) begin
      tr = new();
      assert(tr.randomize());
      drive(tr);
    end

    // Phase 3: final reads
    repeat (2000) begin
      tr = new();
      assert(tr.randomize() with { wr == 0; });
      drive(tr);
    end

    $display("FINAL FUNCTIONAL COVERAGE = %0.2f %%", ck.get_coverage());
    $finish;
  end

endmodule

