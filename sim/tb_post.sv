`timescale 1ns/1ps
module tb_post;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,start=0;
    reg [255:0] biases=0,multipliers=0;
    wire re,we,done,dv;wire [5:0] ra,di;wire [12:0] wa;
    wire [7:0] wd;wire signed [31:0] da;reg signed [31:0] rd;
    reg signed [31:0] data[0:63],expected_acc[0:63];
    reg signed [7:0] expected_q[0:63];reg [7:0] expected_pool[0:15];
    reg signed [63:0] a,p,m,rounded;
    integer i,j,nq=0,na=0,nw=0,cycles=0,address,qi;
    post_processing dut(.clk(clk),.rst(rst),.start(start),.tile_y(7'd6),.tile_x(7'd4),
        .height(7'd16),.width(7'd16),.oc_base(6'd24),.output_base(13'd64),
        .biases(biases),.multipliers(multipliers),.rd_en(re),.rd_addr(ra),.rd_data(rd),
        .wr_en(we),.wr_addr(wa),.wr_data(wd),.done(done),.debug_valid(dv),.debug_acc(da),.debug_index(di));
    always @(posedge clk) begin
        if(re) rd<=data[ra];
        if(!rst) begin
            if(dv) begin
                if(da!==expected_acc[di]) $fatal(1,"post bias mismatch");
                na=na+1;
            end
            // Observe the signed requant result before ReLU destroys negative values.
            if(dut.state==dut.RELU) begin
                if($signed(dut.q)!==expected_q[dut.index])
                    $fatal(1,"requant mismatch index=%0d got=%0d expected=%0d",dut.index,$signed(dut.q),expected_q[dut.index]);
                nq=nq+1;
            end
            if(we) begin
                address=64+(24+nw/2)*64+3*8+2+nw%2;
                if(wd!==expected_pool[nw] || wa!==address[12:0]) $fatal(1,"post pool/address mismatch");
                nw=nw+1;
            end
        end
    end
    initial begin
        for(i=0;i<8;i=i+1) begin
            case(i)
                0,1:multipliers[i*32+:32]=32'd1073741824;
                2:multipliers[i*32+:32]=32'd2147483647;
                3:multipliers[i*32+:32]=32'd742626;
                4:multipliers[i*32+:32]=32'd128780396;
                5:multipliers[i*32+:32]=32'd1;
                6:multipliers[i*32+:32]=32'd0;
                7:multipliers[i*32+:32]=32'd15423668;
            endcase
            biases[i*32+:32]=(i==7)?-123:0;
            for(j=0;j<8;j=j+1) begin
                case(j)
                    0:data[i*8+j]=-3;1:data[i*8+j]=-1;2:data[i*8+j]=1;3:data[i*8+j]=3;
                    4:data[i*8+j]=-255;5:data[i*8+j]=255;
                    6:data[i*8+j]=-2147483000;7:data[i*8+j]=2147483000;
                endcase
            end
        end
        for(i=0;i<16;i=i+1) expected_pool[i]=0;
        for(i=0;i<64;i=i+1) begin
            a=$signed(data[i])+$signed(biases[(i/8)*32+:32]);
            expected_acc[i]=a;
            m=$signed(multipliers[(i/8)*32+:32]);p=a*m;
            rounded=((p<0?-p:p)+64'sd1073741824)/64'sd2147483648;
            if(p<0) rounded=-rounded;
            if(rounded>127) rounded=127;
            if(rounded< -127) rounded=-127;
            expected_q[i]=rounded;
            qi=rounded<0?0:rounded;
            if(qi>expected_pool[i/4]) expected_pool[i/4]=qi;
        end
        repeat(4) @(negedge clk);rst=0;start=1;
        @(negedge clk);start=0;
        while(!done && cycles<2000) begin @(negedge clk);cycles=cycles+1;end
        if(!done || nq!=64 || na!=64 || nw!=16) $fatal(1,"post incomplete");
        $display("PASS tb_post: signed half-away rounding, +/- saturation, zero, bias, pool and address");$finish;
    end
endmodule
