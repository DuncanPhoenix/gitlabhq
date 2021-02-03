import NotificationsForm from '../../../../notifications_form';
import notificationsDropdown from '../../../../notifications_dropdown';
import initNotificationsDropdown from '~/notifications';

document.addEventListener('DOMContentLoaded', () => {
  new NotificationsForm(); // eslint-disable-line no-new
  notificationsDropdown();
  initNotificationsDropdown();
});
