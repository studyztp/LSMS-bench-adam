LSMS_DIR=$(pwd)
cd $LSMS_DIR/FePt/

$LSMS_DIR/build/bin/lsms i_lsms_express_gpu > $LSMS_DIR/FePt/lsms_output.out 2> $LSMS_DIR/FePt/lsms_output.err
