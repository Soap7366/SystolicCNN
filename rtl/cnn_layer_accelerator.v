`timescale 1ns/1ps
module cnn_layer_accelerator #(
    parameter WEIGHT_FILE="data/weights.hex",
    parameter BIAS_FILE="data/bias.hex",
    parameter QUANT_FILE="data/quant.hex"
)(
    input wire clk,rst,start,
    input wire [4:0] cfg_cin,input wire [5:0] cfg_cout,
    input wire [6:0] cfg_height,cfg_width,input wire cfg_src,cfg_dst,
    input wire [12:0] cfg_input_base,cfg_output_base,cfg_weight_base,
    input wire [5:0] cfg_bias_base,cfg_quant_base,
    output wire busy,done,error,
    input wire host_wr_en,host_rd_en,host_bank,
    input wire [12:0] host_addr,input wire [7:0] host_wr_data,
    output reg host_ready,output reg host_rd_valid,output reg [7:0] host_rd_data
);
    wire [4:0] cin;wire [5:0] cout,oc_base;
    wire [6:0] height,width;wire src,dst;
    wire [12:0] input_base,output_base,weight_base;wire [5:0] bias_base,quant_base;
    wire [7:0] k_count;
    wire load_start,load_done,group_start,group_enable,group_done;
    cnn_controller controller(
        .clk(clk),.rst(rst),.start(start),.cfg_cin(cfg_cin),.cfg_cout(cfg_cout),
        .cfg_height(cfg_height),.cfg_width(cfg_width),.cfg_src(cfg_src),.cfg_dst(cfg_dst),
        .cfg_input_base(cfg_input_base),.cfg_output_base(cfg_output_base),.cfg_weight_base(cfg_weight_base),
        .cfg_bias_base(cfg_bias_base),.cfg_quant_base(cfg_quant_base),.busy(busy),.done(done),.error(error),
        .cin(cin),.cout(cout),.oc_base(oc_base),.height(height),.width(width),.src(src),.dst(dst),
        .input_base(input_base),.output_base(output_base),.weight_base(weight_base),
        .bias_base(bias_base),.quant_base(quant_base),.k_count(k_count),
        .load_start(load_start),.load_done(load_done),.group_start(group_start),.group_enable(group_enable),.group_done(group_done));

    wire prep_start,prep_bank,prep_done,prep_busy,array_start,array_bank,array_done,result_bank;
    wire post_start,post_bank,post_done;wire [6:0] prep_y,prep_x,post_y,post_x;
    tile_controller scheduler(.clk(clk),.rst(rst),.start(group_start),.enable(group_enable),
        .height(height),.width(width),.prep_start(prep_start),.prep_bank(prep_bank),
        .prep_y(prep_y),.prep_x(prep_x),.prep_done(prep_done),
        .array_start(array_start),.array_bank(array_bank),.result_bank(result_bank),.array_done(array_done),
        .post_start(post_start),.post_bank(post_bank),.post_y(post_y),.post_x(post_x),.post_done(post_done),.done(group_done));

    wire feature_en;wire [3:0] feature_mask;wire [51:0] feature_addr;wire [31:0] feature_data;
    wire act_wr;wire [3:0] act_ic;wire [71:0] act_top,act_bottom;wire [3:0] act_p;
    prep_controller prep(.clk(clk),.rst(rst),.start(prep_start),.tile_y(prep_y),.tile_x(prep_x),
        .height(height),.width(width),.cin(cin),.input_base(input_base),
        .feature_en(feature_en),.feature_mask(feature_mask),.feature_addr(feature_addr),.feature_data(feature_data),
        .act_wr_en(act_wr),.act_wr_ic(act_ic),.act_wr_p(act_p),.act_wr_top(act_top),.act_wr_bottom(act_bottom),
        .done(prep_done),.busy(prep_busy));
    wire tile_rd;wire [7:0] tile_addr;wire [3:0] act_rd_ic,act_rd_tap;wire [127:0] act_data;wire [63:0] weight_tile_data;
    activation_tile_buffer activation_buffer(.clk(clk),.wr_en(act_wr),.wr_bank(prep_bank),
        .wr_ic(act_ic),.wr_p(act_p),.wr_top(act_top),.wr_bottom(act_bottom),
        .rd_en(tile_rd),.rd_bank(array_bank),.rd_ic(act_rd_ic),.rd_tap(act_rd_tap),.rd_data(act_data));

    wire rom_en,weight_wr;wire [12:0] weight_addr;wire [5:0] bias_addr,quant_addr;
    wire [7:0] weight_data,weight_k,weight_byte;wire [2:0] weight_lane;
    wire [31:0] bias_data,quant_data;wire [255:0] biases,multipliers;
    parameter_rom #(.FILE(WEIGHT_FILE)) weight_rom(.clk(clk),.en(rom_en),.addr(weight_addr),.data(weight_data));
    parameter_rom #(.WIDTH(32),.DEPTH(64),.AW(6),.FILE(BIAS_FILE)) bias_rom(.clk(clk),.en(rom_en),.addr(bias_addr),.data(bias_data));
    parameter_rom #(.WIDTH(32),.DEPTH(64),.AW(6),.FILE(QUANT_FILE)) quant_rom(.clk(clk),.en(rom_en),.addr(quant_addr),.data(quant_data));
    weight_loader loader(.clk(clk),.rst(rst),.start(load_start),.k_count(k_count),.oc_base(oc_base),
        .weight_base(weight_base),.bias_base(bias_base),.quant_base(quant_base),.rom_en(rom_en),
        .weight_addr(weight_addr),.bias_addr(bias_addr),.quant_addr(quant_addr),
        .weight_data(weight_data),.bias_data(bias_data),.quant_data(quant_data),
        .wr_en(weight_wr),.wr_lane(weight_lane),.wr_k(weight_k),.wr_data(weight_byte),
        .biases(biases),.multipliers(multipliers),.done(load_done));
    weight_tile_buffer weight_buffer(.clk(clk),.wr_en(weight_wr),.wr_lane(weight_lane),
        .wr_addr(weight_k),.wr_data(weight_byte),.rd_en(tile_rd),.rd_addr(tile_addr),.rd_data(weight_tile_data));
    wire [127:0] a;wire [63:0] w;wire [15:0] av,al;wire [7:0] wv,wl;wire [4095:0] array_results;
    data_mapper mapper(.clk(clk),.rst(rst),.start(array_start),.k_count(k_count),
        .rd_en(tile_rd),.rd_addr(tile_addr),.act_data(act_data),.weight_data(weight_tile_data),
        .activations(a),.weights(w),.av(av),.wv(wv),.al(al),.wl(wl),.act_rd_ic(act_rd_ic),.act_rd_tap(act_rd_tap));
    systolic_array array(.clk(clk),.rst(rst),.clear(array_start),.activations(a),.weights(w),
        .av(av),.wv(wv),.al(al),.wl(wl),.results(array_results),.done(array_done));

    wire post_rd,post_wr;wire [4:0] post_addr;wire [127:0] post_data;
    wire [12:0] output_addr;wire [7:0] output_data;
    wire debug_valid;wire [127:0] debug_acc;wire [6:0] debug_index;
    output_tile_buffer output_buffer(.clk(clk),.wr_en(array_done),.wr_bank(result_bank),.wr_data(array_results),
        .rd_en(post_rd),.rd_bank(post_bank),.rd_addr(post_addr),.rd_data(post_data));
    post_processing post(.clk(clk),.rst(rst),.start(post_start),.tile_y(post_y),.tile_x(post_x),
        .height(height),.width(width),.oc_base(oc_base),.output_base(output_base),
        .biases(biases),.multipliers(multipliers),.rd_en(post_rd),.rd_addr(post_addr),.rd_data(post_data),
        .wr_en(post_wr),.wr_addr(output_addr),.wr_data(output_data),.done(post_done),
        .debug_valid(debug_valid),.debug_acc(debug_acc),.debug_index(debug_index));

    // Registered external readback avoids a BRAM -> bank mux -> I/O path.
    // start and host accesses must not be issued together (start has priority).
    wire host_accept=host_ready && !start && !rst;
    wire [7:0] a_read,b_read;wire [31:0] a_column,b_column;
    reg host_read_bank,host_read_pending;
    always @(posedge clk) begin
        if(rst) begin host_ready<=0;host_rd_valid<=0;host_read_bank<=0;host_read_pending<=0;host_rd_data<=0;end
        else begin
            host_ready<=!busy && !start;
            host_read_pending<=host_rd_en && host_accept;
            host_rd_valid<=host_read_pending;
            if(host_read_pending) host_rd_data<=host_read_bank?b_read:a_read;
            if(host_rd_en && host_accept) host_read_bank<=host_bank;
        end
    end
    assign feature_data=src?b_column:a_column;
    genvar bank;
    generate for(bank=0;bank<2;bank=bank+1) begin: feature_memories
        wire wr=(busy && post_wr && dst==bank) || (host_accept && host_wr_en && host_bank==bank);
        wire re=host_accept && host_rd_en && host_bank==bank;
        wire [7:0] rd;wire [31:0] column;
        wire [6:0] write_width=busy?(width>>1):((host_bank==cfg_src)?cfg_width:(cfg_width>>1));
        feature_bram ram(.clk(clk),.rst(rst),.wr_en(wr),.wr_width(write_width),
            .wr_addr(busy?output_addr:host_addr),.wr_data(busy?output_data:host_wr_data),
            .rd_en(re),.rd_addr(host_addr),.rd_data(rd),
            .col_en((busy && src==bank)?feature_mask:4'b0),
            .col_addr(feature_addr),.col_width(width),.col_data(column));
        if(bank==0) begin assign a_read=rd;assign a_column=column;end
        else begin assign b_read=rd;assign b_column=column;end
    end endgenerate
endmodule
