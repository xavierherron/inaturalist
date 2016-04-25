import React, { PropTypes, Component } from "react";
import { DragSource, DropTarget } from "react-dnd";
import { Glyphicon, Input, Button } from "react-bootstrap";
import { pipe } from "ramda";
import TaxonAutocomplete from "../../identify/components/taxon_autocomplete";
import Dropzone from "react-dropzone";
import moment from "moment";
import momentLocalizer from "react-widgets/lib/localizers/moment";
import _ from "lodash";
import DateTimeFieldWrapper from "./date_time_field_wrapper";
import FileGallery from "./file_gallery";

momentLocalizer( moment );

const cardSource = {
  beginDrag( props ) {
    props.setState( { draggingProps: props } );
    return props;
  },
  endDrag( props ) {
    props.setState( { draggingProps: null } );
    return props;
  }
};

const cardTarget = {
  canDrop( props, monitor ) {
    const item = monitor.getItem( );
    return item.obsCard.id !== props.obsCard.id;
  },
  drop( props, monitor, component ) {
    if ( monitor.didDrop( ) ) { return; }
    const item = monitor.getItem( );
    const dropResult = component.props;
    if ( dropResult && item.obsCard.id !== props.obsCard.id ) {
      props.mergeObsCards( _.fromPairs(
        _.map( [item.obsCard, dropResult.obsCard], c => [c.id, c] )
      ) );
    }
  }
};

const photoTarget = {
  // don't define canDrop. When a photo is dropped on its own card
  // the action is caught below in drop, and will not fire on drop
  // in the containing div, preventing a new card from being created
  drop( props, monitor, component ) {
    if ( monitor.didDrop( ) ) { return; }
    const item = monitor.getItem( );
    const dropResult = component.props;
    if ( dropResult && item.obsCard.id !== props.obsCard.id ) {
      props.movePhoto( item, dropResult.obsCard );
    }
  }
};

class ObsCardComponent extends Component {

  static collectCard( connect, monitor ) {
    return {
      cardDragSource: connect.dragSource( ),
      cardIsDragging: monitor.isDragging( ),
      cardDragPreview: connect.dragPreview( )
    };
  }

  static collectCardDrop( connect, monitor ) {
    return {
      cardDropTarget: connect.dropTarget( ),
      cardIsOver: monitor.isOver( )
    };
  }

  static collectPhotoDrop( connect, monitor ) {
    return {
      photoDropTarget: connect.dropTarget( ),
      photoIsOver: monitor.isOver( )
    };
  }

  constructor( props, context ) {
    super( props, context );
    this.openLocationChooser = this.openLocationChooser.bind( this );
  }

  shouldComponentUpdate( nextProps ) {
    const b = (
      this.props.photoIsOver !== nextProps.photoIsOver ||
      this.props.cardIsDragging !== nextProps.cardIsDragging ||
      this.props.cardIsOver !== nextProps.cardIsOver ||
      this.props.selected_species_guess !== nextProps.selected_species_guess ||
      Object.keys( this.props.obsCard.files ).length !==
        Object.keys( nextProps.obsCard.files ).length ||
      !_.isMatch( this.props.obsCard, nextProps.obsCard ) );
    return b;
  }

  openLocationChooser( ) {
    this.props.setState( { locationChooser: {
      show: true,
      lat: this.props.obsCard.latitude,
      lng: this.props.obsCard.longitude,
      radius: this.props.obsCard.accuracy,
      obsCard: this.props.obsCard,
      zoom: this.props.obsCard.zoom,
      center: this.props.obsCard.center,
      bounds: this.props.obsCard.bounds,
      geoprivacy: this.props.obsCard.geoprivacy,
      notes: this.props.obsCard.locality_notes
    } } );
  }

  render( ) {
    const { obsCard, cardDropTarget, onCardDrop, cardIsDragging, draggingProps,
      cardIsOver, confirmRemoveObsCard, updateObsCard, setState, selectCard,
      photoDropTarget, cardDragSource, confirmRemoveFile, photoIsOver } = this.props;
    let className = "card ui-selectee";
    if ( cardIsDragging ) { className += " dragging"; }
    if ( cardIsOver || photoIsOver ) { className += " dragOver"; }
    if ( obsCard.selected ) { className += " selected ui-selecting"; }
    if ( obsCard.blank( ) ) { className += " blank"; }
    let globe = (
      <Button onClick={ this.openLocationChooser }>
        <Glyphicon glyph="globe" />
      </Button>
    );
    let locationText = obsCard.locality_notes ||
      ( obsCard.latitude &&
      `${_.round( obsCard.latitude, 4 )},${_.round( obsCard.longitude, 4 )}` );
    return (
      <Dropzone
        className="cellDropzone"
        disableClick
        disablePreview
        onDrop={ ( f, e ) => onCardDrop( f, e, obsCard ) }
        activeClassName="hover"
        accept="image/*"
        key={ obsCard.id }
      >
        <div className="cell">
        {
          cardDropTarget( photoDropTarget( cardDragSource(
            <div
              className={ className }
              data-id={ obsCard.id }
              onClick={ () => selectCard( obsCard ) }
            >
              <div className="close" onClick={ confirmRemoveObsCard }>
                <Glyphicon glyph="remove-sign" />
              </div>
              <FileGallery
                obsCard={ obsCard }
                setState={ setState }
                draggingProps={ draggingProps }
                updateObsCard={ updateObsCard }
                confirmRemoveFile={ confirmRemoveFile }
              />
              <TaxonAutocomplete
                key={ `taxonac${obsCard.selected_species_guess}${obsCard.selected_taxon && obsCard.selected_taxon.id}` }
                bootstrapClear
                searchExternal
                showPlaceholder
                allowPlaceholders
                perPage={ 6 }
                value={ ( obsCard.selected_taxon && obsCard.selected_taxon.id ) ?
                  obsCard.selected_taxon.title : obsCard.species_guess }
                initialSelection={ obsCard.selected_taxon }
                initialTaxonID={ obsCard.taxon_id }
                afterSelect={ result =>
                  updateObsCard( obsCard,
                    { taxon_id: result.item.id, selected_taxon: result.item } )
                }
                afterUnselect={ ( ) => {
                  if ( obsCard.taxon_id ) {
                    updateObsCard( obsCard,
                      { taxon_id: undefined, selected_taxon: undefined } );
                  }
                }}
                onChange={ e => updateObsCard( obsCard, { species_guess: e.target.value } ) }
              />
              <DateTimeFieldWrapper
                key={ `datetime${obsCard.selected_date}`}
                defaultText={ obsCard.date }
                onChange={ dateString =>
                  updateObsCard( obsCard, { date: dateString } )
                }
              />
              <Input type="text" buttonAfter={globe} onClick={ this.openLocationChooser }
                value={ locationText } readOnly
              />
              <Input type="textarea" placeholder="Add a description"
                value={ obsCard.description } onChange={ e =>
                  updateObsCard( obsCard, { description: e.target.value } ) }
              />
            </div>
          ) ) )
        }
        </div>
      </Dropzone>
    );
  }
}

ObsCardComponent.propTypes = {
  obsCard: PropTypes.object,
  confirmRemoveObsCard: PropTypes.func,
  cardDragSource: PropTypes.func,
  cardDragPreview: PropTypes.func,
  cardDropTarget: PropTypes.func,
  photoDropTarget: PropTypes.func,
  cardIsOver: PropTypes.bool,
  photoIsOver: PropTypes.bool,
  cardIsDragging: PropTypes.bool,
  updateObsCard: PropTypes.func,
  onCardDrop: PropTypes.func,
  mergeObsCards: PropTypes.func,
  setState: PropTypes.func,
  selectCard: PropTypes.func,
  selectObsCards: PropTypes.func,
  selectedObsCards: PropTypes.object,
  movePhoto: PropTypes.func,
  draggingProps: PropTypes.object,
  commandKeyPressed: PropTypes.bool,
  shiftKeyPressed: PropTypes.bool,
  confirmRemoveFile: PropTypes.func,
  selected_species_guess: PropTypes.string
};

export default pipe(
  DragSource( "ObsCard", cardSource, ObsCardComponent.collectCard ),
  DropTarget( "ObsCard", cardTarget, ObsCardComponent.collectCardDrop ),
  DropTarget( "Photo", photoTarget, ObsCardComponent.collectPhotoDrop )
)( ObsCardComponent );
