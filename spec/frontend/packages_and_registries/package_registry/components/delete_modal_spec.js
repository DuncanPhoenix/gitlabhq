import { GlModal as RealGlModal, GlSprintf } from '@gitlab/ui';
import { shallowMountExtended } from 'helpers/vue_test_utils_helper';
import { stubComponent } from 'helpers/stub_component';
import DeleteModal from '~/packages_and_registries/package_registry/components/delete_modal.vue';
import {
  DELETE_PACKAGE_MODAL_PRIMARY_ACTION,
  DELETE_PACKAGE_REQUEST_FORWARDING_MODAL_CONTENT,
  DELETE_PACKAGE_WITH_REQUEST_FORWARDING_PRIMARY_ACTION,
  DELETE_PACKAGES_REQUEST_FORWARDING_MODAL_CONTENT,
  DELETE_PACKAGES_WITH_REQUEST_FORWARDING_PRIMARY_ACTION,
} from '~/packages_and_registries/package_registry/constants';

const GlModal = stubComponent(RealGlModal, {
  methods: {
    show: jest.fn(),
  },
});

describe('DeleteModal', () => {
  let wrapper;

  const defaultItemsToBeDeleted = [
    {
      name: 'package 01',
      version: '1.0.0',
    },
    {
      name: 'package 02',
      version: '1.0.0',
    },
  ];

  const findModal = () => wrapper.findComponent(GlModal);

  const mountComponent = ({
    itemsToBeDeleted = defaultItemsToBeDeleted,
    showRequestForwardingContent = false,
  } = {}) => {
    wrapper = shallowMountExtended(DeleteModal, {
      propsData: {
        itemsToBeDeleted,
        showRequestForwardingContent,
      },
      stubs: {
        GlModal,
        GlSprintf,
      },
    });
  };

  beforeEach(() => {
    mountComponent();
  });

  it('passes title prop', () => {
    expect(findModal().props('title')).toMatchInterpolatedText('Delete packages');
  });

  it('passes actionPrimary prop', () => {
    expect(findModal().props('actionPrimary')).toStrictEqual({
      text: 'Permanently delete',
      attributes: { variant: 'danger', category: 'primary' },
    });
  });

  it('renders description', () => {
    expect(findModal().text()).toMatchInterpolatedText(
      'You are about to delete 2 packages. This operation is irreversible.',
    );
  });

  it('with only one item to be deleted renders correct description', () => {
    mountComponent({ itemsToBeDeleted: [defaultItemsToBeDeleted[0]] });

    expect(findModal().text()).toMatchInterpolatedText(
      'You are about to delete version 1.0.0 of package 01. Are you sure?',
    );
  });

  it('sets the right action primary text', () => {
    expect(findModal().props('actionPrimary')).toMatchObject({
      text: DELETE_PACKAGE_MODAL_PRIMARY_ACTION,
    });
  });

  describe('when showRequestForwardingContent is set', () => {
    it('renders correct description', () => {
      mountComponent({ showRequestForwardingContent: true });

      expect(findModal().text()).toMatchInterpolatedText(
        DELETE_PACKAGES_REQUEST_FORWARDING_MODAL_CONTENT,
      );
    });

    it('sets the right action primary text', () => {
      mountComponent({ showRequestForwardingContent: true });

      expect(findModal().props('actionPrimary')).toMatchObject({
        text: DELETE_PACKAGES_WITH_REQUEST_FORWARDING_PRIMARY_ACTION,
      });
    });

    describe('and only one item to be deleted', () => {
      beforeEach(() => {
        mountComponent({
          showRequestForwardingContent: true,
          itemsToBeDeleted: [defaultItemsToBeDeleted[0]],
        });
      });

      it('renders correct description', () => {
        expect(findModal().text()).toMatchInterpolatedText(
          DELETE_PACKAGE_REQUEST_FORWARDING_MODAL_CONTENT,
        );
      });

      it('sets the right action primary text', () => {
        expect(findModal().props('actionPrimary')).toMatchObject({
          text: DELETE_PACKAGE_WITH_REQUEST_FORWARDING_PRIMARY_ACTION,
        });
      });
    });
  });

  it('emits confirm when primary event is emitted', () => {
    expect(wrapper.emitted('confirm')).toBeUndefined();

    findModal().vm.$emit('primary');

    expect(wrapper.emitted('confirm')).toHaveLength(1);
  });

  it('emits cancel when cancel event is emitted', () => {
    expect(wrapper.emitted('cancel')).toBeUndefined();

    findModal().vm.$emit('cancel');

    expect(wrapper.emitted('cancel')).toHaveLength(1);
  });

  it('show calls gl-modal show', () => {
    findModal().vm.show();

    expect(GlModal.methods.show).toHaveBeenCalled();
  });
});
