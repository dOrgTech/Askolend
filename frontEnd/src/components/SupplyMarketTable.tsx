import { Avatar, Grid, Switch, Typography } from '@material-ui/core';
import { CollateralDialog, ConfirmationDialog } from '../components'
import { Token, getTokenLogoPngSrc } from '../models'

import Paper from '@material-ui/core/Paper';
import React from 'react';
import Table from '@material-ui/core/Table';
import TableBody from '@material-ui/core/TableBody';
import TableCell from '@material-ui/core/TableCell';
import TableContainer from '@material-ui/core/TableContainer';
import TableHead from '@material-ui/core/TableHead';
import TableRow from '@material-ui/core/TableRow';
import { connect } from 'react-redux'

interface ISupplyMarketTableProps {
    tokenInfos?: [],
}

interface ISupplyMarketTableState {
    collateralopen: boolean,
    confirmationOpen: boolean,
    confirmationTitle: string,
    selectedToken: Token | undefined
}

class SupplyMarketTableClass extends React.Component<ISupplyMarketTableProps, ISupplyMarketTableState>  {
    constructor(props: any) {
        super(props);
        this.state = {
            collateralopen: false,
            confirmationOpen: false,
            confirmationTitle: '',
            selectedToken: undefined,
        };
        this.collateralSwitchClick.bind(this);
    }

    collateralClose = () => {
        this.setState({ collateralopen: false });
    }

    collateralSwitchClick = (event: any, token: Token) => {
        this.setState({
            collateralopen: !this.state.collateralopen,
            selectedToken: token
        });
    }

    collateralSet = (collateralized: boolean, collateral: Token, confirmationMessage: string) => {
        if (collateralized !== collateral.collateral) {
            this.setState({ confirmationOpen: true, confirmationTitle: confirmationMessage});
            // TO-DO: Implement collateral action in https://github.com/AskobarNetwork/Askolend/issues/22
        }
        else {
            console.warn(`Collateral for ${collateral.address} is already set to ${collateral.collateral}, no action taken`);
        }
    }

    confirmationClose = () => {
        this.setState({ confirmationOpen: false });
    }

    render() {
        return (
            <React.Fragment>
                <ConfirmationDialog {...{
                    confirmationClose: this.confirmationClose,
                    confirmationOpen: this.state.confirmationOpen,
                    title: this.state.confirmationTitle
                }}
                />
                <TableContainer component={Paper}>
                    <Table>
                        <TableHead>
                            <TableRow>
                                <TableCell>Asset</TableCell>
                                <TableCell align='right'>APY</TableCell>
                                <TableCell align='center'>Wallet</TableCell>
                                <TableCell align='center'>Collateral</TableCell>
                            </TableRow>
                        </TableHead>
                        <TableBody>
                            {this.props.tokenInfos?.map((token: any) => (
                                <TableRow key={token.value.asset}>
                                    <TableCell align='left'>
                                        <Grid
                                            container
                                            direction='row'
                                            justify='flex-start'
                                            alignItems='center'
                                        >
                                            <Avatar src={getTokenLogoPngSrc(token.value.address)} alt={token.value.asset} /> &nbsp;
                                    <Typography>{token.value.asset}</Typography>
                                        </Grid>
                                    </TableCell>
                                    <TableCell align='right'>{token.value.apy + '%'}</TableCell>
                                    <TableCell align='center'>{0}</TableCell>
                                    <TableCell align='center'>
                                        <Switch checked={token.value.collateral} onClick={(event) => this.collateralSwitchClick(event, token.value)}></Switch>
                                        <CollateralDialog {... {
                                            collateralClose: this.collateralClose,
                                            collateralSet: this.collateralSet,
                                            collateralOpen: this.state.collateralopen,
                                            token: this.state.selectedToken
                                        }}
                                        />
                                    </TableCell>
                                </TableRow>
                            ))}
                        </TableBody>
                    </Table>
                </TableContainer>
            </React.Fragment>
        );
    }
}

const mapStateToProps = (state: any) => {
    return {
        tokenInfos: state.tokenInfo.tokenInfos,
    }
}

const SupplyMarketTable = connect(mapStateToProps, null)(SupplyMarketTableClass)

export { SupplyMarketTable };