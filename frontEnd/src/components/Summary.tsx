import { Grid } from '@material-ui/core';
import React from 'react';
import Typography from '@material-ui/core/Typography';
import { makeStyles } from '@material-ui/core/styles';

export function Summary() {
    const classes = useStyles();

    return (
        <div className={classes.summary}>
            <Grid
                container
                direction="row"
                justify="space-evenly"
                alignItems="center"
            >
                <Grid
                >
                    <Typography variant="h5" gutterBottom>
                        Supply Balance
                    </Typography>
                    <Typography variant="h6" gutterBottom>
                        $0
                    </Typography>
                    <Typography variant="h5" gutterBottom>
                        Net APY
                    </Typography>
                    <Typography variant="h6" gutterBottom>
                        --
                    </Typography>
                </Grid>
                <Grid
                >
                    <Typography variant="h5" gutterBottom>
                        Borrow Balance
                    </Typography>
                    <Typography variant="h6" gutterBottom>
                        $0
                    </Typography>
                    <Typography variant="h5" gutterBottom>
                        Borrow Limit
                    </Typography>
                    <Typography variant="h6" gutterBottom>
                        0%
                    </Typography>
                </Grid>
            </Grid>

            <Typography>You can only use Low Risk as collateral.</Typography>
            <Typography>You can only specific one type of collateral when borrowing an asset.</Typography>
        </div>
    );
}

const useStyles = makeStyles((theme) => ({
    summary: {
        flexGrow: 1,
        padding: '30px',
    },
}));